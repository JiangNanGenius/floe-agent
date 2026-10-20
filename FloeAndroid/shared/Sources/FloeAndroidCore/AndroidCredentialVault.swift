// SPDX-License-Identifier: MPL-2.0
//
// Android credential vault (G02 RB-2b owned-operations source candidate,
// job-07f0d672e3854e17, correcting the recovery candidate job-06f6addd2fdb4271
// against Main findings CV-R1/CV-R2/CV-R3/CV-R4).
//
// One metadata authority (the original FloePersistence.CredentialStore over
// the original DatabaseManager/schema 46) and one secret authority (the
// existing fail-closed typed async AndroidSecretGateway behind the frozen
// SecretGatewayRegistry). There is no second business database, no secret
// file, no RAM secret store, no host Keychain fallback and no second durable
// cursor: the ONLY cleanup-intent durability is the EXISTING original
// `credential_deletion_queue` table (V11ArchiveCredentials) in the SAME
// DatabaseManager that owns `credential_records`. The vault creates its
// CredentialStore internally from the one DatabaseManager it is admitted
// with, so the queue and the metadata cannot point at different databases by
// construction.
//
// OWNED OPERATION LIFETIME (Main findings CV-R1/CV-R2, 2026-10-19 — the
// correction this round implements):
//   The recovery candidate coordinated live operations with per-actor RAM
//   sets (`accountsInFlight` / `accountsDraining` / `mutationsInFlight`).
//   That was provably insufficient: `processIntentRow` excluded only
//   `accountsDraining` while `beginAccountMutation` excluded only
//   `accountsInFlight`, so the SAME actor's drain could treat a live
//   capture's in-flight claim as a crash orphan and delete its secret before
//   the metadata commit; the inverse race existed; and a second vault over
//   the same DatabaseManager had entirely separate gates. Live operation
//   ownership now lives in ONE shared `CredentialVaultOperationCoordinator`
//   admitted per exact trusted runtime identity (normalized root path +
//   FULL owner token + typed epoch from RB1's `RuntimeOwnerIdentity` — the
//   full identity, never the 4-byte diagnostic fingerprint, never model
//   JSON):
//     * every gateway side effect, metadata truth resolution and queue
//       bookkeeping of capture / replace / register / targeted cleanup /
//       global drain / discard / success finalization runs under one current
//       account lease held across ALL its awaits, including cancellation
//       and error paths;
//     * a lease is released ONLY when the owning operation has actually
//       settled — there is no timer, no elapsed-time release, and no detach
//       merely because a caller resumed or cancelled while an awaited effect
//       can still complete (the operation's body awaits the effect itself
//       before it unwinds);
//     * startup recovery distinguishes a CURRENTLY OWNED operation (live
//       lease → skip; the owner will settle it) from a PROvably retired or
//       process-dead prior ownership (no lease in the fresh RAM coordinator
//       → the durable original queue row IS the recovery authority — no
//       caller-retained UUID cleanup is reintroduced);
//     * each owned operation additionally attaches/detaches the REAL RB1
//       `RuntimeOwnedWorkRegistry` kind `.vaultMaintenance` (composed via
//       `VaultOwnedWorkAttaching`; the production default forwards to the
//       actual shared registry — attach before the first durable side
//       effect, detach only after final queue bookkeeping). RB1's stop
//       drains this registry and refuses new attaches; the vault fails
//       closed on typed admission errors instead of inventing a parallel
//       fence.
//
// QUEUE GROUND TRUTH (CV-R2): `enqueued_at` is the original trigger's
// `datetime('now')` second-resolution wall clock. It is NOT an operation
// generation: two delete/reinsert operations in the same second produce an
// identical (account, enqueued_at) tuple (Main's extracted-DDL reproduction:
// MAIN_SQL_COUNTEREXAMPLES_20261019.py). This candidate does NOT pretend the
// timestamp is a generation. It uses (a) the actual scoped operation token
// above with enforced serialization — while a lease is live NO supported
// operation can remove/reinsert that account's row, so a stale finalizer can
// never observe a "new" same-tuple row at all; plus (b) conditional SQL:
// every queue removal is re-validated in one writer transaction (observed
// row still exists with the expected tuple AND the live-metadata truth
// matches the operation's expectation). Residual honest boundary: an
// UNCOORDINATED writer (second OS process, or direct SQL outside the
// admitted runtime) is explicitly NOT made safe — admission fail-closes any
// duplicate runtime owner over the same root or the same physical manager,
// and the supported single-owner product context is what the safety claims
// cover (Main: never advertise impossible blanket safety).
//
// BOUNDED FAIR TRAVERSAL (CV-R3): the global drain walks the ORIGINAL queue
// with a keyset cursor over `(enqueued_at, keychain_account)` — the exact
// deterministic order of the stored rows — instead of OFFSET, which assumed
// failed/skipped rows never disappear or reorder under concurrent awaits.
// The cursor advances past every row the call visited (completed, failed,
// cleared, skipped), so later rows are never starved behind a failing front,
// each visited row is attempted at most once per call, memory is bounded to
// the current batch plus two cursor strings, and the work budget is explicit
// (`truncatedBudget` is reported truthfully; rows beyond the budget and rows
// enqueued during the call surface in the exact final `remaining` count for
// the next service-owned drain). No second persistent queue/cursor/index/
// schema/DB; original UNIQUE/PK lookups stay bounded.
//
// GATEWAY FAILURE SEMANTICS (CV-R4): `SecretBackendError.dispatcherUnresponsive`
// is NOT proof of "no effect". The actual SecretGatewayMailbox watchdog emits
// the SAME error for tickets already in `.claimed` state
// (SecretGatewayMailbox.swift lines 923..934: state moves to
// `callerSettledExecutionOutstanding` and the permit/effect-unknown book is
// retained) as for never-dispatched queued tickets. The vault therefore
// classifies it conservatively as `.effectUnknown`: never a durable-claim
// release on the error alone; compensation-then-truth decides the outcome
// (a provably authoritative compensating delete may finalize the claim;
// anything else keeps the durable cleanup intent — typed pending, never fake
// compensation success). Provably pre-queue rejections (`mailboxSaturated`,
// `backendBusy`, `invalidReference`, `invalidValue`, `intentRejected`) are
// emitted only by `makeTicket`/`publish` BEFORE a ticket is ever queued
// (SecretGatewayMailbox.swift lines 271..315) and keep the `.rejected`
// classification; final authority for those sites remains the pending
// gateway qualifier (job-cd5b38d6b6204b13).
//
// Payload bytes never enter SQLite: the queue stores only the original
// columns (account / synchronizable / enqueued_at / redacted last_error).
//
// Narrow mirrored SQL over the ORIGINAL existing tables is used only where
// an atomic invariant requires it (claim, conditional revalidated
// finalization, keyed EXISTS lookups, bounded keyset cleanup projections).
// It creates no schema, no index and never edits upstream: the original
// CredentialStore.save stays the metadata authority; row semantics match
// V11ArchiveCredentials.swift (columns, datetime('now') timestamps, INSERT
// OR IGNORE trigger behaviour, account-PK single row per account).
//
// This file is a PRIVATE SOURCE CANDIDATE. The source-authoring package does
// not compile, execute or publish it. Gateway qualification (job-cd5…),
// RB1 concrete API reconciliation (runtime-bootstrap-main-reviewed-source;
// this file references its admitted `RuntimeOwnerIdentity` /
// `RuntimeFacadeCode` / owned-work types and MUST be published together with
// or after them), Swift 6 object/actor-isolation qualification of the
// lease/defer flows below, native/App/device/product-UID proof and Main
// publication remain separate gates.
import Foundation
import GRDB
import FloeCore
import FloePersistence

// MARK: - Public value surface

/// The stable, secret-free handle returned to callers. It is the same shape as
/// the iOS FloeSync type; FloeSync itself is intentionally not linked here.
public struct CredentialHandle: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

/// The only vault operation the credential-argument normalizer needs. Keeping
/// this narrow is what lets the original normalizer mirror stay byte-identical
/// apart from the parameter type.
public protocol CredentialCapturing: Sendable {
    func capture(
        _ secret: Data,
        kind: CredentialKind,
        owner: CredentialOwner,
        label: String,
        hostID: UUID?,
        origin: String?
    ) async throws -> CredentialHandle
}

/// Coarse, non-secret classification used by diagnostics and by the vault's
/// truthful failure reporting. No underlying localized error text is retained:
/// an exception message may contain credential-bearing text.
public enum CredentialGatewayFailureKind: Sendable, Equatable {
    /// No gateway is registered (fail-closed production state).
    case unavailable
    /// The gateway rejected the request before any store operation. This is
    /// ONLY used for statuses that are source-proven to be emitted before a
    /// ticket is ever queued (see `failureKind(for:)` and CV-R4).
    case rejected
    /// The request may have reached the store. The caller must not infer
    /// "no effect".
    case effectUnknown
}

public enum AndroidCredentialVaultError: Error, Equatable, Sendable {
    case invalidSecret
    case invalidAccount
    case credentialNotFound(UUID)
    case credentialConflict(UUID)
    case operationInFlight(UUID)
    /// Retained for public-surface stability only. Same-account contention is
    /// now resolved by the shared coordinator's FIFO lease wait (CV-R1), so
    /// the vault never throws this case; a caller waiting on a live owner is
    /// either granted when that owner settles or fails with cancellation.
    case accountInFlight
    /// The canonical reference still has a durable pending-cleanup row that
    /// cannot be completed. The row owns the cleanup; capture and
    /// registration refuse rather than write around it.
    case referenceCleanupPending(UUID)
    case secretMissing(UUID)
    case gatewayFailure(operation: SecretOperation, kind: CredentialGatewayFailureKind)
    /// The gateway write outcome was unknown, but the compensating delete
    /// completed. Metadata was never written and the durable claim row was
    /// finalized.
    case gatewayWriteEffectUnknownCompensated(UUID)
    /// Cancellation was observed after the write; the compensating delete
    /// completed and metadata was never written.
    case captureCancelledSecretRemoved(UUID)
    /// Metadata failed, the compensating delete completed, and no record was
    /// written. The durable claim row was finalized.
    case captureMetadataFailedSecretRemoved(UUID)
    /// Metadata failed or a write outcome was unknown and the compensating
    /// delete did not complete. The secret may still exist under this handle's
    /// canonical reference. The durable cleanup intent REMAINS in the original
    /// queue, so restart `drainDeletionQueue()` can recover the account
    /// without any caller-retained id; the id here is advisory only.
    case captureCleanupIncomplete(UUID)
    /// Metadata save failed and readback could not prove absence. The secret
    /// was retained so a possibly-committed record is not left without one,
    /// and the durable claim row stays for the restart decision table
    /// (live metadata -> obsolete intent cleared, secret preserved).
    case captureMetadataUncertain(UUID)
    /// The secret was written, but the conservative metadata update failed.
    /// The existing record still addresses the same canonical reference.
    case replaceMetadataFailed(UUID)
    case metadataWriteFailed(UUID)
    case metadataDeleteFailed(UUID)
    case syncUnavailable
    /// `discardUncommittedSecret` refuses: the canonical reference has no
    /// durable owned cleanup-intent row in the original queue. Public discard
    /// may never delete an arbitrary unregistered reference.
    case durableCleanupIntentMissing(UUID)
    /// The factory refused a duplicate/incompatible runtime ownership
    /// (CV-R1: two independent coordinators over one root/DB fail closed with
    /// the reviewed RB1 lifecycle code — never a silent parallel gate).
    case ownershipAdmissionRejected(RuntimeFacadeCode)
    /// The REAL owned-work registry refused the per-operation
    /// `.vaultMaintenance` attach (e.g. `.notInstalled` before the owned
    /// store is ready, `.alreadyDraining` after a stop). The operation fails
    /// closed BEFORE any durable side effect.
    case ownedWorkAdmissionRejected(RuntimeFacadeCode)
    /// The owned-work registry reported a structurally invalid owner
    /// identity. No durable effect.
    case ownedWorkAdmissionInvalidIdentity
    /// `retireRuntimeOwnership()` refuses while the shared coordinator still
    /// has live leases, waiters or handle mutations. Retirement is a fence,
    /// not a timer: call it only after the operations have actually settled.
    case ownershipRetirementBlocked
}

/// Android has no CloudKit/iCloud secret path. The only truthful status is
/// that synchronization is unavailable; it is never advertised as usable.
public enum AndroidCredentialSyncStatus: Sendable, Equatable {
    case syncUnavailable

    public var isSyncUsable: Bool { false }
}

public enum CredentialSecretCleanup: Sendable, Equatable {
    case completed
    case pendingDurableQueue
    case unknown
}

public struct CredentialDeletionOutcome: Sendable, Equatable {
    public let metadataExisted: Bool
    public let secretCleanup: CredentialSecretCleanup

    public init(metadataExisted: Bool, secretCleanup: CredentialSecretCleanup) {
        self.metadataExisted = metadataExisted
        self.secretCleanup = secretCleanup
    }
}

public struct CredentialDeletionDrainReport: Sendable, Equatable {
    /// Exact `SELECT COUNT(*)` over the original queue at call start.
    public let pendingAtStart: Int
    /// Rows whose gateway delete became authoritative and whose generation
    /// conditionally finalized.
    public let completed: Int
    /// Rows whose gateway delete failed, whose completion could not be
    /// durably finalized, or whose conservative guard deferred the row to
    /// the next service-owned drain.
    public let failed: Int
    /// Rows cleared in the same writer transaction because the ORIGINAL
    /// metadata still references the account: a committed credential survives
    /// and its secret is NEVER deleted.
    public let clearedObsolete: Int
    /// Rows whose account has a LIVE owner in the shared coordinator (an
    /// in-flight capture/replace/register/delete/discard lease) or whose
    /// observed row/metadata truth advanced under the decision transaction.
    /// Never treated as crash orphans (CV-R1).
    public let skippedConcurrent: Int
    /// True when the drain's explicit pass budget was exhausted while more
    /// rows were still queued in the stored order; the next service-owned
    /// drain continues from the durable truth.
    public let truncatedBudget: Bool
    /// Non-nil when the REAL owned-work registry refused the drain's
    /// `.vaultMaintenance` attach; the drain then performed NO side effects
    /// and touched NO queue rows.
    public let ownedWorkAdmissionRejected: RuntimeFacadeCode?
    /// `nil` when the post-drain count query failed.
    public let remaining: Int?
    /// True only when a queue query failed.
    public let queryFailed: Bool

    public init(
        pendingAtStart: Int,
        completed: Int,
        failed: Int,
        clearedObsolete: Int,
        skippedConcurrent: Int,
        truncatedBudget: Bool = false,
        ownedWorkAdmissionRejected: RuntimeFacadeCode? = nil,
        remaining: Int?,
        queryFailed: Bool
    ) {
        self.pendingAtStart = pendingAtStart
        self.completed = completed
        self.failed = failed
        self.clearedObsolete = clearedObsolete
        self.skippedConcurrent = skippedConcurrent
        self.truncatedBudget = truncatedBudget
        self.ownedWorkAdmissionRejected = ownedWorkAdmissionRejected
        self.remaining = remaining
        self.queryFailed = queryFailed
    }

    public static func queryFailure() -> CredentialDeletionDrainReport {
        CredentialDeletionDrainReport(
            pendingAtStart: 0, completed: 0, failed: 0, clearedObsolete: 0,
            skippedConcurrent: 0, remaining: nil, queryFailed: true)
    }

    public static func ownedWorkRefused(
        _ code: RuntimeFacadeCode
    ) -> CredentialDeletionDrainReport {
        CredentialDeletionDrainReport(
            pendingAtStart: 0, completed: 0, failed: 0, clearedObsolete: 0,
            skippedConcurrent: 0, truncatedBudget: false,
            ownedWorkAdmissionRejected: code, remaining: nil, queryFailed: false)
    }
}

// MARK: - Fail-closed registry forwarder (retained from the parent candidate)

/// Real forwarding gateway over the frozen fail-closed `SecretGatewayRegistry`.
///
/// The frozen `CredentialBackend.swift` registry is a `@unchecked Sendable`
/// class that owns registration state and CRUD passthrough but does NOT
/// declare conformance to `AndroidSecretGateway`; asserting an empty
/// retroactive conformance would be inventing conformance in a source-only
/// claim, which Main rejected. This wrapper is a real owned type with three
/// forwarding methods: while no gateway is registered every call still
/// throws `SecretGatewayError.needsConfiguration` (the registry's own
/// fail-closed behaviour), and once the JNI gateway registers, calls pass
/// through unchanged. It stores nothing and adds no memory fallback.
public struct SecretGatewayRegistryForwarder: AndroidSecretGateway {
    private let registry: SecretGatewayRegistry

    public init(registry: SecretGatewayRegistry = SecretGatewayRegistry.shared) {
        self.registry = registry
    }

    public func read(reference: String) async throws -> Data? {
        try await registry.read(reference: reference)
    }

    public func write(reference: String, value: Data) async throws {
        try await registry.write(reference: reference, value: value)
    }

    public func delete(reference: String) async throws {
        try await registry.delete(reference: reference)
    }
}

/// CV-R4 actual-mailbox binding: the forwarder resolves the CURRENT
/// underlying observing gateway for ONE attempt. The forwarder itself is
/// deliberately NOT a `PhysicalObservingSecretGateway` — it must never
/// become the retained witness, because a later registry replacement would
/// then re-point the truth of an OLD receipt at a different backend. Only
/// the actual gateway that minted the individual receipt is retained.
extension SecretGatewayRegistryForwarder: PhysicalObservationResolving {
    public func currentPhysicalObserver() -> (any PhysicalObservingSecretGateway)? {
        registry.currentPhysicalObserver()
    }
}

// MARK: - Internal durable shapes

/// A cleanup-intent row projection from the ORIGINAL queue table. Only the
/// original columns participate; secret bytes never do.
struct CredentialCleanupRow: Sendable, Equatable {
    let account: String
    let enqueuedAt: String
}

/// Result of the atomic account claim transaction.
enum CredentialAccountClaim: Sendable, Equatable {
    /// The claim row is durable; carries its own `enqueued_at` value. This
    /// value is a second-resolution wall clock — an OBSERVATION used for
    /// conditional revalidation, NOT a unique operation generation (CV-R2).
    case claimed(enqueuedAt: String)
    /// Live original metadata already references the account.
    case metadataPresent
    /// A cleanup intent row owns the account (live or durable-unowned).
    case intentPresent
}

/// Decision produced atomically inside one original writer transaction when
/// a recovery drain examines a durable intent row WHILE HOLDING THE CURRENT
/// ACCOUNT LEASE.
enum CredentialIntentDecision: Sendable, Equatable {
    /// The account still has committed metadata: the intent is obsolete
    /// (capture died after its metadata commit but before finalization). The
    /// row was cleared in the SAME transaction and the secret was not
    /// touched.
    case liveMetadataCleared
    /// The exact observed row vanished or advanced under the decision
    /// transaction. NOTHING may be deleted on this observation (CV-R2
    /// stale-side-effect fix: even the no-live-metadata path now REQUIRES
    /// the observed row to still exist with the expected tuple before any
    /// gateway delete).
    case generationAdvanced
    /// No live metadata references the account AND the observed row still
    /// exists with the expected tuple: the gateway delete is owed.
    case cleanupRequired
}

/// Outcome vocabulary of one processed queue row.
enum CredentialIntentOutcome: Sendable, Equatable {
    case gatewayDeleteCompleted
    case obsoleteCleared
    case failed
    case skippedConcurrent
}

// MARK: - Vault

/// One vault wrapper performs its coordinated mutations through the admitted
/// shared coordinator; a runtime admits exactly ONE ownership context for its
/// one `DatabaseManager`/root+epoch and any number of vault WRAPPERS may join
/// that same context (they then share every handle/account gate — the CV-R1
/// second-vault fix). The vault constructs THE original `CredentialStore`
/// over that manager and exports it (`records`), so the RB1 graph reuses the
/// same single store instance; queue work then provably runs against the
/// identical database.
public actor AndroidCredentialVault: CredentialCapturing {
    /// Android saved-credential sync is not implemented. No API advertises it
    /// as usable and no code reads a different (synchronized) namespace.
    public static let savedCredentialSyncAvailable = false

    private static let referenceNamespace = "keychainAccount"

    /// Bounded cleanup projection size. Every drain pass fetches at most this
    /// many projected rows through the keyset cursor.
    static let cleanupBatchLimit = 16

    /// The one original metadata store, constructed here over the one
    /// DatabaseManager. Exported for RB1 reuse; the vault's own metadata
    /// authority is this exact instance.
    public let records: CredentialStore

    private let database: DatabaseManager
    private let gateway: any AndroidSecretGateway
    private let now: @Sendable () -> Date
    private let identity: RuntimeOwnerIdentity
    private let coordinator: CredentialVaultOperationCoordinator
    private let ownedWork: any VaultOwnedWorkAttaching

    /// The admitted epoch of this wrapper's runtime context (typed host
    /// epoch). Equality/admission on the full identity stays inside the
    /// admission state; the owner token itself is never exposed.
    public var runtimeEpoch: UInt64 { identity.epoch }
    /// Short non-reversible diagnostic of the runtime root (RB1 rule: the
    /// fingerprint is never used for admission and never carries a path).
    public var runtimeRootFingerprint: String { identity.root.fingerprint }

    /// The designated initializer is PRIVATE: a production vault can only be
    /// created through `joinRuntimeOwnership`, so an uncoordinated duplicate
    /// owner over the same root/epoch or the same physical DatabaseManager is
    /// structurally impossible (CV-R1 constructor requirement).
    private init(
        database: DatabaseManager,
        identity: RuntimeOwnerIdentity,
        coordinator: CredentialVaultOperationCoordinator,
        ownedWork: any VaultOwnedWorkAttaching,
        gateway: any AndroidSecretGateway,
        now: @escaping @Sendable () -> Date
    ) {
        self.database = database
        self.identity = identity
        self.coordinator = coordinator
        self.ownedWork = ownedWork
        self.records = CredentialStore(database: database)
        self.gateway = gateway
        self.now = now
    }

    /// Admit (or join) one vault wrapper for the trusted runtime context.
    ///
    /// The caller is the host runtime owner (RB1's `AndroidRuntimeStoreOwner`
    /// after its owned store is `.ready`): the `identity` is the host's FULL
    /// `RuntimeOwnerIdentity` (exact normalized root + full owner token +
    /// typed epoch), never a fingerprint or model-supplied value, and the
    /// `database` is the runtime's ONE migrated `DatabaseManager`. The
    /// returned vault's exported `records` store is the single store
    /// instance the graph should reuse. Admission rules (fail-closed,
    /// reviewed RB1 equality semantics):
    ///   * same full identity + same epoch + same manager → shared
    ///     coordinator (supported multi-wrapper use);
    ///   * newer epoch while any owned operation is live →
    ///     `.rebindWhileOwned` (retirement fence first);
    ///   * newer epoch with a provably idle prior coordinator → replacement
    ///     context (the in-process mirror of "prior ownership retired"; on a
    ///     real process restart the RAM coordinator simply does not exist
    ///     and the durable original queue is the recovery authority);
    ///   * different full owner over the same root → `.ownerMismatch`;
    ///   * the same manager already bound under another root →
    ///     `.lifecycleConflict` (separate RAM gates over one physical DB is
    ///     exactly the bug CV-R1 proved).
    /// The default `ownedWork` is the REAL shared `RuntimeOwnedWorkRegistry`
    /// port — never a default fake zero.
    public static func joinRuntimeOwnership(
        database: DatabaseManager,
        identity: RuntimeOwnerIdentity,
        ownedWork: any VaultOwnedWorkAttaching = RuntimeOwnedWorkRegistryAttachment.shared,
        gateway: any AndroidSecretGateway = SecretGatewayRegistryForwarder(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> AndroidCredentialVault {
        let admission = CredentialVaultRuntimeAdmission.admit(
            identity: identity, database: database)
        switch admission.outcome {
        case .rejected(let code):
            throw AndroidCredentialVaultError.ownershipAdmissionRejected(code)
        case .joinedSharedContext, .admittedNewContext:
            guard let coordinator = admission.coordinator else {
                throw AndroidCredentialVaultError.ownershipAdmissionRejected(.internal)
            }
            return AndroidCredentialVault(
                database: database,
                identity: identity,
                coordinator: coordinator,
                ownedWork: ownedWork,
                gateway: gateway,
                now: now)
        }
    }

    /// In-process retirement of THIS wrapper's runtime context after the
    /// owned operations have actually settled. It releases only the RAM
    /// coordination gates; the durable original queue is untouched and stays
    /// the recovery authority for the next owner (which the admission fence
    /// admits only under a newer typed epoch — production retirement order is
    /// RB1's own stop receipt + `waitForDrain` of the real owned-work
    /// registry, which this vault composes, never duplicates).
    public func retireRuntimeOwnership() throws {
        guard !coordinator.hasLiveOperations else {
            throw AndroidCredentialVaultError.ownershipRetirementBlocked
        }
        if let code = CredentialVaultRuntimeAdmission.retire(
            identity: identity, coordinator: coordinator) {
            throw AndroidCredentialVaultError.ownershipAdmissionRejected(code)
        }
    }

    /// Truthful, secret-free diagnostics of the shared coordinator.
    public var ownedOperationSummary: (accounts: Int, handles: Int, waiting: Int) {
        coordinator.liveOperationSummary
    }

    /// Test-only deterministic scheduling seam for the cancellation /
    /// registration race (CV-R1 follow-up). Never called by product code;
    /// the interposer is installed on the SHARED coordinator, so tests that
    /// install it must clear it before the owner operation proceeds.
    internal func setAcquireRegistrationInterposerForTesting(
        _ interposer: (@Sendable (String) -> Void)?
    ) {
        coordinator.setRegistrationInterposerForTesting(interposer)
    }

    /// Test-only observation seam for the controlled two-reconciler overlap
    /// (account, reservationGranted). Never used by product code.
    internal func setReconciliationProbeForTesting(
        _ probe: (@Sendable (String, Bool) -> Void)?
    ) {
        coordinator.setReconciliationProbeForTesting(probe)
    }

    // MARK: Owned operation lifetime helpers (CV-R1 composition point)

    /// Wait for the shared coordinator's account lease (FIFO, cancellation
    /// safe) and map coordination errors onto the public vocabulary. The
    /// lease is the scoped operation token: every later effect of this
    /// operation re-checks `coordinator.isCurrent(lease)` before acting.
    private func acquireLease(
        _ account: String,
        kind: CredentialVaultOperationCoordinator.LeaseKind
    ) async throws -> VaultAccountLease {
        do {
            return try await coordinator.acquireAccount(account, kind: kind)
        } catch let error as CredentialVaultCoordinationError {
            switch error {
            case .operationInFlight(let target):
                throw AndroidCredentialVaultError.operationInFlight(target)
            case .cancelledWhileWaiting:
                throw CancellationError()
            }
        }
    }

    /// Attach the REAL registry receipt for one owned operation. Throws the
    /// typed admission error if the actual RB1 lifecycle refuses the attach
    /// (store not ready / stop requested) — always BEFORE any durable effect.
    private func attachOwnedWork() throws -> String {
        switch ownedWork.attachVaultMaintenance(
            epoch: identity.epoch, ownerID: coordinator.ownerID) {
        case .attached(let receipt):
            return receipt
        case .rejected(let code):
            throw AndroidCredentialVaultError.ownedWorkAdmissionRejected(code)
        case .invalidIdentity:
            throw AndroidCredentialVaultError.ownedWorkAdmissionInvalidIdentity
        }
    }

    /// Settle the receipt first, then the lease. BOTH are synchronous, which
    /// is exactly what lets ownership unwind through `defer` AFTER the
    /// operation body (including its compensations and queue bookkeeping)
    /// has fully settled. The body never returns while an awaited effect can
    /// still land, so this is never a detach on a mere caller cancellation.
    private func settleOwnedOperation(receipt: String, lease: VaultAccountLease) {
        _ = ownedWork.detachVaultMaintenance(
            receipt: receipt, epoch: identity.epoch, ownerID: coordinator.ownerID)
        coordinator.release(lease)
    }

    /// Begin one owned account operation: lease, then receipt. If the receipt
    /// attach fails the lease is released immediately (no effect started),
    /// and the typed error propagates.
    private func beginOwnedAccountOperation(
        _ account: String,
        kind: CredentialVaultOperationCoordinator.LeaseKind
    ) async throws -> (VaultAccountLease, String) {
        let lease = try await acquireLease(account, kind: kind)
        do {
            let receipt = try attachOwnedWork()
            return (lease, receipt)
        } catch {
            coordinator.release(lease)
            throw error
        }
    }

    /// Maps the coordinator's typed handle error onto the public error
    /// surface (same semantics as the parent candidate, now SHARED across
    /// every wrapper over this runtime context).
    private func beginHandleGuard(_ id: UUID) throws {
        do {
            try coordinator.beginHandle(id)
        } catch let error as CredentialVaultCoordinationError {
            switch error {
            case .operationInFlight(let target):
                throw AndroidCredentialVaultError.operationInFlight(target)
            case .cancelledWhileWaiting:
                throw CancellationError()
            }
        }
    }

    // MARK: - Individual physical settlement (CV-R4 actual-mailbox binding)
    //
    // The mailbox watchdog resumes a CLAIMED ticket's caller with
    // `dispatcherUnresponsive` while the real store execution is still
    // running (`callerSettledExecutionOutstanding`, permit retained). The
    // caller error is therefore NOT settlement. When the attempt-time gateway
    // supports individual physical receipts, this vault settles an unknown
    // write ONLY on that exact claim's terminal truth:
    //   * `neverDispatched` / proven no-effect status → the write provably
    //     never reached the store: release the durable claim;
    //   * `settled(3)` (committed) → an orphan secret exists: compensate and
    //     require the compensating delete's OWN physical truth (a committed
    //     delete is real quiescence for this record's traced store lane) to
    //     finalize the claim; anything less keeps the durable row;
    //   * any other terminal / honest `.notRecorded` → effect unproven: keep
    //     the durable claim row as the recovery authority and settle the
    //     in-process owner;
    //   * still outstanding (watchdog resumed the caller, cancellation
    //     arrived, or the compensation itself is still executing) → transfer
    //     the live work to an EXPLICIT long-lived pending owner that keeps
    //     the account lease + registry receipt until reconciliation observes
    //     the real terminal. A caller error, cancellation, timeout or the
    //     durable-row-created event is never treated as settlement.

    /// Resolve the attempt-time physical observer, mirroring
    /// `PhysicalObservationResolver` semantics exactly: a registry-backed
    /// seam resolves its CURRENT underlying gateway (the registry itself
    /// also conforms as a forwarding shim, so a plain cast would wrongly
    /// claim observation survives replacement); a directly-bound observing
    /// gateway is used as-is; anything else yields nil — honest non-evidence
    /// that keeps the conservative compensation-then-truth rules.
    private static func physicalObserver(
        for gateway: any AndroidSecretGateway
    ) -> (any PhysicalObservingSecretGateway)? {
        if let resolving = gateway as? any PhysicalObservationResolving {
            return resolving.currentPhysicalObserver()
        }
        return gateway as? any PhysicalObservingSecretGateway
    }

    /// Await the REAL individual terminal physical truth for one observed
    /// claim. Notification-based (no polling, no timer): the mailbox
    /// subscription resumes on a terminal record (or `.notRecorded`), except
    /// when THIS task is cancelled — then the current snapshot is returned
    /// honestly and is never treated as settlement.
    private func awaitPhysicalTerminal(
        _ witness: any PhysicalObservingSecretGateway, claim: Int64
    ) async -> PhysicalOperationSnapshot {
        var snapshot = witness.physicalSnapshot(claim: claim)
        while true {
            switch snapshot {
            case .queued, .claimedOutstanding:
                if Task.isCancelled { return snapshot }
                snapshot = await witness.awaitPhysicalSettlement(claim: claim)
            case .settled, .neverDispatched, .notRecorded:
                return snapshot
            }
        }
    }

    /// The mailbox's own terminal-effect table applied to a WRITE
    /// (`SecretGatewayMailbox.recordEffectLocked` mirror): 3 is the only
    /// valid committed write status; -1/-2/-9/-13/-15 are the proven
    /// no-effect set; every other terminal leaves the effect unproven
    /// (including -11/-12/-14, whose own comment says the store may have
    /// completed, and the storage/keystore families) so the durable claim
    /// row is retained.
    private enum ObservedWriteEffect {
        case committed
        case noEffect
        case unknown
    }

    private static func observedWriteEffect(_ status: Int32) -> ObservedWriteEffect {
        switch status {
        case 3: return .committed
        case -1, -2, -9, -13, -15: return .noEffect
        default: return .unknown
        }
    }

    /// Park the live work in the coordinator's explicit pending-owner table.
    /// The lease stays CURRENT (no newer owner can take the account, the
    /// retirement fence refuses, the rebind fence refuses) and the registry
    /// receipt stays attached until `reconcilePendingPhysicalOwners()`
    /// observes the real terminal truth through the EXACT witness.
    private func parkPendingPhysicalOwner(
        account: String,
        lease: VaultAccountLease,
        registryReceipt: String,
        claim: Int64,
        compensationClaim: Int64?,
        witness: any PhysicalObservingSecretGateway,
        enqueuedAt: String,
        reference: String
    ) {
        coordinator.parkPendingPhysical(CredentialVaultPendingPhysicalOwner(
            account: account,
            lease: lease,
            registryReceipt: registryReceipt,
            claim: claim,
            compensationClaim: compensationClaim,
            witness: witness,
            enqueuedAt: enqueuedAt,
            reference: reference))
    }

    /// Settle an UNKNOWN observed secret write from its individual physical
    /// truth (see the section comment). Always throws the public typed
    /// outcome; `ownershipRetained` is set when the live work was transferred
    /// to a pending owner instead of being unwound by the capture defer.
    private func settleUnknownObservedWrite(
        observer: any PhysicalObservingSecretGateway,
        receipt: PhysicalOperationReceipt,
        account: String,
        lease: VaultAccountLease,
        registryReceipt: String,
        id: UUID,
        reference: String,
        enqueuedAt: String,
        ownershipRetained: inout Bool
    ) async throws {
        let settlement = await awaitPhysicalTerminal(observer, claim: receipt.claim)
        switch settlement {
        case .neverDispatched:
            // Provable no-effect: the ticket left the mailbox before any
            // poller could claim it (the frozen dispatcher's claim→store
            // launch segment is non-suspending), so no store ever saw it.
            _ = observer.resolvePhysical(claim: receipt.claim)
            await releaseClaimQuietly(account: account, enqueuedAt: enqueuedAt)
            coordinator.setClaimGeneration(lease, generation: nil)
            throw AndroidCredentialVaultError.gatewayWriteEffectUnknownCompensated(id)
        case .settled(let status):
            switch Self.observedWriteEffect(status) {
            case .noEffect:
                _ = observer.resolvePhysical(claim: receipt.claim)
                await releaseClaimQuietly(account: account, enqueuedAt: enqueuedAt)
                coordinator.setClaimGeneration(lease, generation: nil)
                throw AndroidCredentialVaultError.gatewayWriteEffectUnknownCompensated(id)
            case .committed:
                // The write really landed: keep its record until the
                // compensation decision consumes it.
                try await settleCommittedObservedWrite(
                    observer: observer,
                    writeClaim: receipt.claim,
                    account: account,
                    lease: lease,
                    registryReceipt: registryReceipt,
                    id: id,
                    reference: reference,
                    enqueuedAt: enqueuedAt,
                    compensationClaim: nil,
                    ownershipRetained: &ownershipRetained)
            case .unknown:
                // Terminal but not provable: the durable claim row stays the
                // recovery authority; the in-process owner settles.
                _ = observer.resolvePhysical(claim: receipt.claim)
                throw AndroidCredentialVaultError.captureCleanupIncomplete(id)
            }
        case .notRecorded:
            // HONEST NON-EVIDENCE IS NOT SETTLEMENT (Main CV-MAIN-NOTRECORDED):
            // the individual record is gone (mailbox reset / untracked /
            // externally consumed) while the real execution may still exist.
            // Keep the exact witness + account lease + registry receipt
            // QUARANTINED as an explicit pending owner; never ACK absence as
            // a completed physical terminal and never release the owner.
            ownershipRetained = true
            parkPendingPhysicalOwner(
                account: account,
                lease: lease,
                registryReceipt: registryReceipt,
                claim: receipt.claim,
                compensationClaim: nil,
                witness: observer,
                enqueuedAt: enqueuedAt,
                reference: reference)
            throw AndroidCredentialVaultError.captureCleanupIncomplete(id)
        case .queued, .claimedOutstanding:
            // Cancelled while the real execution is still outstanding:
            // transfer the live work instead of dropping the lease/receipt.
            ownershipRetained = true
            parkPendingPhysicalOwner(
                account: account,
                lease: lease,
                registryReceipt: registryReceipt,
                claim: receipt.claim,
                compensationClaim: nil,
                witness: observer,
                enqueuedAt: enqueuedAt,
                reference: reference)
            throw AndroidCredentialVaultError.captureCleanupIncomplete(id)
        }
    }

    /// The write physically COMMITTED: an orphan secret exists under the
    /// canonical reference. Attempt (or adopt) the compensating delete and
    /// retain ownership until ITS individual physical truth.
    private func settleCommittedObservedWrite(
        observer: any PhysicalObservingSecretGateway,
        writeClaim: Int64,
        account: String,
        lease: VaultAccountLease,
        registryReceipt: String,
        id: UUID,
        reference: String,
        enqueuedAt: String,
        compensationClaim: Int64?,
        ownershipRetained: inout Bool
    ) async throws {
        var claim = compensationClaim
        if claim == nil {
            let capture = ReceiptCapture()
            do {
                try await observer.deleteObserved(reference: reference) { receipt in
                    capture.set(receipt)
                }
            } catch {
                // Caller-resumed before the delete terminal: the individual
                // record (delivered at queue-accept) is still the truth.
            }
            claim = capture.receipt?.claim
        }
        guard let claim else {
            // The compensation provably never reached the queue, so the
            // committed write's secret still exists: keep the durable row.
            _ = observer.resolvePhysical(claim: writeClaim)
            throw AndroidCredentialVaultError.captureCleanupIncomplete(id)
        }
        let settlement = await awaitPhysicalTerminal(observer, claim: claim)
        switch settlement {
        case .settled(let status) where status == 4:
            // Authoritative compensating delete completed: quiescent for
            // this record's traced store lane.
            _ = observer.resolvePhysical(claim: claim)
            _ = observer.resolvePhysical(claim: writeClaim)
            await releaseClaimQuietly(account: account, enqueuedAt: enqueuedAt)
            coordinator.setClaimGeneration(lease, generation: nil)
            throw AndroidCredentialVaultError.gatewayWriteEffectUnknownCompensated(id)
        case .settled, .neverDispatched:
            // A real terminal for the delete that did NOT commit: the secret
            // may still exist → durable row stays; the owner settles.
            _ = observer.resolvePhysical(claim: claim)
            _ = observer.resolvePhysical(claim: writeClaim)
            throw AndroidCredentialVaultError.captureCleanupIncomplete(id)
        case .notRecorded:
            // The delete's individual record is gone (non-evidence, not a
            // terminal). Quarantine the exact witness + lease + receipt with
            // the in-flight claim adopted; never release on absence.
            ownershipRetained = true
            parkPendingPhysicalOwner(
                account: account,
                lease: lease,
                registryReceipt: registryReceipt,
                claim: writeClaim,
                compensationClaim: claim,
                witness: observer,
                enqueuedAt: enqueuedAt,
                reference: reference)
            throw AndroidCredentialVaultError.captureCleanupIncomplete(id)
        case .queued, .claimedOutstanding:
            // The compensation itself is still executing (watchdog resumed
            // its caller, or this task was cancelled): park the live work.
            ownershipRetained = true
            parkPendingPhysicalOwner(
                account: account,
                lease: lease,
                registryReceipt: registryReceipt,
                claim: writeClaim,
                compensationClaim: claim,
                witness: observer,
                enqueuedAt: enqueuedAt,
                reference: reference)
            throw AndroidCredentialVaultError.captureCleanupIncomplete(id)
        }
    }

    /// Service-owned reconciliation of explicit long-lived pending physical
    /// owners. Settles each owner ONLY on the real individual terminal truth
    /// of its EXACT captured witness (never the current registry, never a
    /// counter, never a timer, never honest `.notRecorded` non-evidence).
    /// Returns how many owners finished (and thus released their account
    /// lease and `.vaultMaintenance` receipt).
    ///
    /// SINGLEFLIGHT (Main CV-MAIN-RECONCILE-REENTRANCY): actors are
    /// reentrant and any number of vault wrappers share one coordinator, so
    /// TWO reconcilers can snapshot the SAME pending owner. The shared
    /// coordinator grants an exact reservation per owner BEFORE any await or
    /// side effect; only the holder may initiate/adopt a compensation or
    /// settle. A second reconciler observes no reservation, performs NO
    /// effect, and returns. On cancellation the reservation is released
    /// (ownership handoff) and the owner stays parked for the next call.
    ///
    /// Startup order (RB1 host): call this BEFORE `drainDeletionQueue()` so a
    /// previous attempt's settled physical truth is consumed before the
    /// durable queue decides on the account.
    @discardableResult
    public func reconcilePendingPhysicalOwners() async -> Int {
        var finished = 0
        for owner in coordinator.pendingPhysicalOwners() {
            guard let reservation =
                    coordinator.tryAcquirePendingReconciliation(owner) else {
                // Another reconciler owns this exact owner (or it is stale):
                // perform NO effect here.
                continue
            }
            let settled = await reconcilePendingPhysicalOwner(
                owner, reservation: reservation)
            if settled {
                finished += 1
            } else {
                // Not settlement (outstanding / unobserved / cancelled):
                // hand the reservation back; the owner remains parked.
                coordinator.releasePendingReconciliation(reservation)
            }
        }
        return finished
    }

    private func reconcilePendingPhysicalOwner(
        _ owner: CredentialVaultPendingPhysicalOwner,
        reservation: PendingReconciliationLease
    ) async -> Bool {
        let writeSettlement = await awaitPhysicalTerminal(owner.witness, claim: owner.claim)
        switch writeSettlement {
        case .queued, .claimedOutstanding:
            // Still outstanding (only reachable via cancellation): the owner
            // stays parked; its lease/receipt remain attached.
            return false
        case .neverDispatched:
            _ = owner.witness.resolvePhysical(claim: owner.claim)
            return await finishPendingPhysicalOwner(
                owner, finalizeRow: true, reservation: reservation)
        case .notRecorded:
            // HONEST NON-EVIDENCE IS NOT SETTLEMENT: keep the owner
            // quarantined with its exact witness/lease/receipt. Absence of a
            // record never proves the real Root work ended.
            return false
        case .settled(let status):
            switch Self.observedWriteEffect(status) {
            case .noEffect:
                _ = owner.witness.resolvePhysical(claim: owner.claim)
                return await finishPendingPhysicalOwner(
                    owner, finalizeRow: true, reservation: reservation)
            case .unknown:
                _ = owner.witness.resolvePhysical(claim: owner.claim)
                return await finishPendingPhysicalOwner(
                    owner, finalizeRow: false, reservation: reservation)
            case .committed:
                guard let compensated = await reconcilePendingCompensation(
                    owner, reservation: reservation) else {
                    return false
                }
                _ = owner.witness.resolvePhysical(claim: owner.claim)
                return await finishPendingPhysicalOwner(
                    owner, finalizeRow: compensated, reservation: reservation)
            }
        }
    }

    /// The compensating delete's individual truth for a parked owner.
    /// `true` = committed (orphan secret provably gone); `false` = a real
    /// terminal that did not commit (row retained, owner may settle);
    /// `nil` = still outstanding, unobserved (`.notRecorded`) or the wait was
    /// cancelled — the owner stays parked and quarantined.
    private func reconcilePendingCompensation(
        _ owner: CredentialVaultPendingPhysicalOwner,
        reservation: PendingReconciliationLease
    ) async -> Bool? {
        if let claim = owner.compensationClaim {
            let settlement = await awaitPhysicalTerminal(owner.witness, claim: claim)
            switch settlement {
            case .queued, .claimedOutstanding, .notRecorded:
                return nil
            case .settled(let status):
                _ = owner.witness.resolvePhysical(claim: claim)
                return status == 4
            case .neverDispatched:
                _ = owner.witness.resolvePhysical(claim: claim)
                return false
            }
        }
        // Compensation was never initiated: do it now under the retained
        // lease and THIS exclusive reservation (no other reconciler can
        // enqueue a second old delete).
        let capture = ReceiptCapture()
        do {
            try await owner.witness.deleteObserved(reference: owner.reference) { receipt in
                capture.set(receipt)
            }
        } catch {
            // Caller-resumed: the delivered receipt below still decides.
        }
        guard let fresh = capture.receipt else {
            // The observed publish provably never accepted a ticket (the
            // receipt is delivered atomically on queue-accept), so THIS
            // compensation attempt never dispatched. That is a proven
            // no-dispatch for this attempt, not an unobserved terminal.
            return false
        }
        guard coordinator.adoptCompensationClaim(
            owner, claim: fresh.claim, reservation: reservation) else {
            // The reservation was lost (cancellation handoff): the owner
            // keeps its previous state; the next reconciliation adopts the
            // claim it observes.
            return nil
        }
        let settlement = await awaitPhysicalTerminal(owner.witness, claim: fresh.claim)
        switch settlement {
        case .queued, .claimedOutstanding, .notRecorded:
            // The claim is adopted: the next reconciliation awaits THIS
            // delete instead of initiating a second one.
            return nil
        case .settled(let status):
            _ = owner.witness.resolvePhysical(claim: fresh.claim)
            return status == 4
        case .neverDispatched:
            _ = owner.witness.resolvePhysical(claim: fresh.claim)
            return false
        }
    }

    /// Exactly-once owner settlement under the EXACT reservation and lease:
    /// finalize the durable row first (only when the physical truth proved
    /// it), then release the lease and detach the REAL registry receipt. A
    /// second reconciler can never settle (no reservation) and a stale lease
    /// can never admit a newer owner early.
    private func finishPendingPhysicalOwner(
        _ owner: CredentialVaultPendingPhysicalOwner,
        finalizeRow: Bool,
        reservation: PendingReconciliationLease
    ) async -> Bool {
        if finalizeRow {
            _ = try? await finalizeAccountClaim(
                account: owner.account,
                enqueuedAt: owner.enqueuedAt,
                requiresLiveMetadata: false)
        }
        guard coordinator.settlePendingPhysical(owner, reservation: reservation) else {
            return false
        }
        _ = ownedWork.detachVaultMaintenance(
            receipt: owner.registryReceipt,
            epoch: identity.epoch,
            ownerID: coordinator.ownerID)
        return true
    }

    // MARK: Capture

    /// Captures secret bytes for arbitrary tool arguments. The full signature
    /// mirrors `FloeSync.CredentialVaultService.capture`; the id is supplied
    /// by the caller (the normalizer lets the vault mint one).
    @discardableResult
    public func capture(
        _ secret: Data,
        kind: CredentialKind,
        owner: CredentialOwner,
        label: String,
        id: UUID,
        hostID: UUID? = nil,
        origin: String? = nil,
        deviceBound: Bool = false
    ) async throws -> CredentialHandle {
        try Task.checkCancellation()
        try Self.validate(secret)
        try beginHandleGuard(id)
        defer { coordinator.endHandle(id) }
        let account = Self.keychainAccount(for: id)
        let (lease, registryReceipt) =
            try await beginOwnedAccountOperation(account, kind: .capture)
        // Ownership unwinds here ONLY when this operation has actually
        // settled its durable bookkeeping. A path that transfers the live
        // work to an explicit long-lived pending physical owner clears this
        // flag first (CV-R4): a caller error, watchdog resume or cancellation
        // never detaches an effect that can still land.
        var ownershipRetained = false
        defer {
            if !ownershipRetained {
                settleOwnedOperation(receipt: registryReceipt, lease: lease)
            }
        }
        // The body below is the capture effect itself; EVERY path settles
        // its durable bookkeeping before it returns/throws, so the deferred
        // settle is the "actual operation completion" boundary.

        // A late capture must never overwrite an existing row (the original
        // store's save is an UPSERT). Normalizer ids are fresh, so this only
        // guards deliberate or late reuse. Targeted PK lookup only.
        let existingRecord = try await records.record(id: id)
        if existingRecord != nil {
            throw AndroidCredentialVaultError.credentialConflict(id)
        }

        // Durable account claim BEFORE any secret write. One writer
        // transaction: no live metadata for the account, no previous intent,
        // INSERT the claim into the ORIGINAL queue, read back its
        // second-resolution generation value. The value is recorded on the
        // CURRENT lease so a nested targeted cleanup under this same lease
        // can never finalize the row this operation is still awaiting on.
        let enqueuedAt = try await claimAccountForWrite(
            account: account,
            lease: lease,
            refusal: .credentialConflict(id),
            pendingError: .referenceCleanupPending(id))

        do {
            // Mirror the original #6 semantics: attach the optional host
            // foreign key only when the host is already durable.
            let durableHostID: UUID?
            if let hostID {
                let hostIsDurable = try await records.hostExists(id: hostID)
                durableHostID = hostIsDurable ? hostID : nil
            } else {
                durableHostID = nil
            }

            let timestamp = now()
            let record = CredentialRecord(
                id: id,
                kind: kind,
                owner: owner,
                hostID: durableHostID,
                origin: origin,
                label: label,
                keychainAccount: account,
                synchronizable: false,
                deviceBound: deviceBound,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            let reference = Self.reference(for: account)

            // Secret first: metadata must never point at a missing secret.
            // Any error observed BEFORE this point leaves nothing durable
            // behind, so the pre-write do/catch below releases the claim.
            //
            // CV-R4 actual-mailbox binding: when the ATTEMPT-TIME gateway
            // supports individual physical receipts, the write is issued
            // through the observed seam and the receipt identifies THIS
            // operation's backend truth. An unobserving gateway keeps the
            // exact parent conservative rules.
            let physicalObserver = Self.physicalObserver(for: gateway)
            let writeReceipt = ReceiptCapture()
            do {
                if let physicalObserver {
                    try await physicalObserver.writeObserved(
                        reference: reference, value: secret
                    ) { receipt in
                        writeReceipt.set(receipt)
                    }
                } else {
                    try await gateway.write(reference: reference, value: secret)
                }
            } catch {
                let failure = Self.failureKind(for: error)
                guard failure == .effectUnknown else {
                    // Provably no effect (pre-queue rejection ONLY — see
                    // CV-R4; `dispatcherUnresponsive` never takes this
                    // path). Release OUR OWN claim under the
                    // no-live-metadata guard so the account is not blocked
                    // by an intent that matches no secret. A concurrent newer
                    // intent can never appear: this account lease is live
                    // for the whole operation.
                    await releaseClaimQuietly(account: account, enqueuedAt: enqueuedAt)
                    coordinator.setClaimGeneration(lease, generation: nil)
                    throw AndroidCredentialVaultError.gatewayFailure(
                        operation: .write, kind: failure)
                }
                if let physicalObserver, let observed = writeReceipt.receipt {
                    // The caller was resumed (watchdog `dispatcherUnresponsive`,
                    // cancellation, replaced generation) but the individual
                    // execution may still land: settle ONLY on this claim's
                    // real terminal truth, retaining the lease + registry
                    // receipt until then.
                    try await settleUnknownObservedWrite(
                        observer: physicalObserver,
                        receipt: observed,
                        account: account,
                        lease: lease,
                        registryReceipt: registryReceipt,
                        id: id,
                        reference: reference,
                        enqueuedAt: enqueuedAt,
                        ownershipRetained: &ownershipRetained)
                }
                // Unobserved attempt (or no individual record was minted): the
                // parent compensation-then-truth rules. The durable claim row
                // is the recovery authority; a failed compensation is never
                // reported as success and never releases the claim.
                let compensated = await deleteSecret(reference: reference)
                if compensated {
                    await releaseClaimQuietly(account: account, enqueuedAt: enqueuedAt)
                    coordinator.setClaimGeneration(lease, generation: nil)
                    throw AndroidCredentialVaultError.gatewayWriteEffectUnknownCompensated(id)
                }
                // Compensation failed: the durable claim row STAYS. Restart
                // drain sees no metadata for the account, deletes the orphan
                // secret and finalizes. No caller-retained UUID is required.
                // The claim generation stays recorded on the lease only while
                // it is current; after the deferred settle the row is by
                // definition a durable-UNOWNED recovery authority.
                throw AndroidCredentialVaultError.captureCleanupIncomplete(id)
            }

            // A cancellation after a write must not create metadata; clean
            // up the possible secret and report the real outcome. The lease
            // and the registry receipt STAY HELD until this compensation
            // settles — cancellation alone never releases ownership.
            if Task.isCancelled {
                let compensated = await deleteSecret(reference: reference)
                if compensated {
                    await releaseClaimQuietly(account: account, enqueuedAt: enqueuedAt)
                    coordinator.setClaimGeneration(lease, generation: nil)
                    throw AndroidCredentialVaultError.captureCancelledSecretRemoved(id)
                }
                throw AndroidCredentialVaultError.captureCleanupIncomplete(id)
            }

            // Metadata commit through the ORIGINAL store; the claim row
            // stays durable until this succeeds.
            do {
                try await records.save(record)
            } catch {
                // The save error alone cannot prove the row is absent. If
                // rollback is uncertain, keep the secret AND the claim: the
                // restart decision table then sees live metadata + stale
                // intent and clears the intent without touching the secret.
                let readback: CredentialRecord?
                do {
                    readback = try await records.record(id: id)
                } catch {
                    throw AndroidCredentialVaultError.captureMetadataUncertain(id)
                }
                if readback != nil {
                    throw AndroidCredentialVaultError.captureMetadataUncertain(id)
                }
                let compensated = await deleteSecret(reference: reference)
                if compensated {
                    await releaseClaimQuietly(account: account, enqueuedAt: enqueuedAt)
                    coordinator.setClaimGeneration(lease, generation: nil)
                    throw AndroidCredentialVaultError.captureMetadataFailedSecretRemoved(id)
                }
                throw AndroidCredentialVaultError.captureCleanupIncomplete(id)
            }

            // Durable metadata success: finalize OUR generation, conditioned
            // in-transaction on (row exists + tuple match + live metadata
            // for this account). If that DB write fails or the guard defers,
            // the row simply survives to the next drain, which observes the
            // live metadata and clears it as obsolete — the credential is
            // already durable, so the handle is returned after the actual
            // metadata commit either way.
            _ = try? await finalizeAccountClaim(
                account: account,
                enqueuedAt: enqueuedAt,
                requiresLiveMetadata: true)
            coordinator.setClaimGeneration(lease, generation: nil)
            return CredentialHandle(id: id)
        } catch let error as AndroidCredentialVaultError {
            throw error
        } catch {
            // Pre-write failure (host check etc.): nothing durable was
            // written, so release our claim generation.
            await releaseClaimQuietly(account: account, enqueuedAt: enqueuedAt)
            coordinator.setClaimGeneration(lease, generation: nil)
            throw error
        }
    }

    /// Protocol witness used by the normalizer mirror. The normalizer never
    /// supplies an id or a device-bound preference.
    public func capture(
        _ secret: Data,
        kind: CredentialKind,
        owner: CredentialOwner,
        label: String,
        hostID: UUID? = nil,
        origin: String? = nil
    ) async throws -> CredentialHandle {
        try await capture(
            secret,
            kind: kind,
            owner: owner,
            label: label,
            id: UUID(),
            hostID: hostID,
            origin: origin,
            deviceBound: false
        )
    }

    // MARK: Metadata-only mutation

    /// Replaces the secret bytes of an existing credential in place, keeping
    /// its stable id (and every ⟨credential:id⟩ reference). Android cannot
    /// mirror the iOS synchronized copy; the record is normalized to local-only
    /// after a successful write.
    ///
    /// Staged-capture semantics: the metadata row is ALREADY live, so an
    /// in-place overwrite can never orphan a secret and no claim is minted.
    /// A durable intent for the account (from a settled prior operation) is
    /// completed targeted-first under THIS lease and the replace refuses
    /// while one persists.
    public func replaceSecret(_ handle: CredentialHandle, secret: Data) async throws {
        try Task.checkCancellation()
        try Self.validate(secret)
        try beginHandleGuard(handle.id)
        defer { coordinator.endHandle(handle.id) }
        // The record read happens under the same lease as the whole replace
        // effect; a live drain can no longer observe this account mid-flight
        // (CV-R1 inverse direction).
        let account = try await accountOfRecord(handle.id)
        let (lease, receipt) = try await beginOwnedAccountOperation(account, kind: .replace)
        defer { settleOwnedOperation(receipt: receipt, lease: lease) }

        let reference = Self.reference(for: account)
        try await ensureAccountDrainedOrRefused(account: account, handleID: handle.id, under: lease)

        do {
            try await gateway.write(reference: reference, value: secret)
        } catch {
            // A failed write may have overwritten the old value. Do not
            // claim no effect; the same reference is still the record's
            // authority.
            throw AndroidCredentialVaultError.gatewayFailure(
                operation: .write, kind: Self.failureKind(for: error))
        }

        guard var record = try await records.record(id: handle.id) else {
            throw AndroidCredentialVaultError.credentialNotFound(handle.id)
        }
        record.synchronizable = false
        record.updatedAt = now()
        do {
            try await records.save(record)
        } catch {
            // The secret is already applied. Deleting it would destroy an
            // existing credential; report that only the metadata update
            // failed.
            throw AndroidCredentialVaultError.replaceMetadataFailed(handle.id)
        }
    }

    /// Updates secret-free metadata (label) without touching the secret.
    /// Metadata-only: the shared handle guard keeps it out of the same
    /// record's write operations; no queue or gateway effect exists, so no
    /// account lease/receipt is minted.
    public func updateLabel(_ handle: CredentialHandle, label: String) async throws {
        try Task.checkCancellation()
        try beginHandleGuard(handle.id)
        defer { coordinator.endHandle(handle.id) }
        guard var record = try await records.record(id: handle.id) else {
            throw AndroidCredentialVaultError.credentialNotFound(handle.id)
        }
        record.label = label
        record.synchronizable = false
        record.updatedAt = now()
        try Task.checkCancellation()
        do {
            try await records.save(record)
        } catch {
            throw AndroidCredentialVaultError.metadataWriteFailed(handle.id)
        }
    }

    public func promoteToVault(_ handle: CredentialHandle) async throws {
        try Task.checkCancellation()
        try beginHandleGuard(handle.id)
        defer { coordinator.endHandle(handle.id) }
        guard var record = try await records.record(id: handle.id) else {
            throw AndroidCredentialVaultError.credentialNotFound(handle.id)
        }
        record.owner = .vault
        record.synchronizable = false
        record.updatedAt = now()
        try Task.checkCancellation()
        do {
            try await records.save(record)
        } catch {
            throw AndroidCredentialVaultError.metadataWriteFailed(handle.id)
        }
    }

    /// Registers an already-existing local gateway item (host migration). The
    /// account string is metadata only and is never returned to callers.
    /// Requesting sync is rejected BEFORE any metadata effect.
    ///
    /// A pending cleanup intent blocks registration around the account (the
    /// atomic claim below refuses while one persists): registering metadata
    /// that a later drain would orphan is not allowed. The claim + the live
    /// account lease protect the check-vs-save window the same way they
    /// protect capture; a save failure releases the claim so the
    /// pre-existing item is never deleted. The residual crash window is
    /// documented in HANDOFF.md: a claim that survives a process death with
    /// NO committed metadata is drained as an orphan cleanup, which for this
    /// rare migration path means the register attempt must be redone against
    /// a re-supplied item.
    public func registerExisting(
        account: String,
        kind: CredentialKind,
        label: String,
        hostID: UUID? = nil,
        synchronizable: Bool,
        deviceBound: Bool = false
    ) async throws {
        try Task.checkCancellation()
        guard !synchronizable else {
            throw AndroidCredentialVaultError.syncUnavailable
        }
        guard !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AndroidCredentialVaultError.invalidAccount
        }
        let (lease, receipt) = try await beginOwnedAccountOperation(account, kind: .register)
        defer { settleOwnedOperation(receipt: receipt, lease: lease) }

        let record = CredentialRecord(
            kind: kind,
            owner: .vault,
            hostID: hostID,
            label: label,
            keychainAccount: account,
            synchronizable: false,
            deviceBound: deviceBound
        )

        // Idempotence + pending-intent refusal come from the same atomic
        // claim (targeted UNIQUE/PK lookups): metadata present -> nothing to
        // do; durable intent present (after one targeted drain attempt under
        // this lease) -> refuse rather than register around it.
        let enqueuedAt: String
        switch try await claimAccount(account: account) {
        case .metadataPresent:
            return
        case .intentPresent:
            _ = await drainAccountIntent(account: account, under: lease)
            switch try await claimAccount(account: account) {
            case .metadataPresent: return
            case .intentPresent:
                throw AndroidCredentialVaultError.referenceCleanupPending(record.id)
            case .claimed(let generation):
                enqueuedAt = generation
            }
        case .claimed(let generation):
            enqueuedAt = generation
        }
        coordinator.setClaimGeneration(lease, generation: enqueuedAt)

        do {
            try await records.save(record)
        } catch {
            // Registration never committed. Release OUR OWN generation only,
            // under the no-live-metadata guard.
            _ = try? await finalizeAccountClaim(
                account: account,
                enqueuedAt: enqueuedAt,
                requiresLiveMetadata: false)
            coordinator.setClaimGeneration(lease, generation: nil)
            throw AndroidCredentialVaultError.metadataWriteFailed(record.id)
        }
        _ = try? await finalizeAccountClaim(
            account: account,
            enqueuedAt: enqueuedAt,
            requiresLiveMetadata: true)
        coordinator.setClaimGeneration(lease, generation: nil)
    }

    // MARK: Resolution / status

    /// Executor-only resolution. UI/model layers must not expose the result.
    /// Android reads the SINGLE canonical local reference; a legacy
    /// `synchronizable` flag does not select or imply a second store.
    /// Reads mint no lease/receipt: they have no durable side effect and a
    /// gateway read survives the surrounding lifecycle by design (RB1: an
    /// effect read survives the old generation).
    public func resolveForApprovedUse(_ handle: CredentialHandle) async throws -> Data {
        try Task.checkCancellation()
        guard let record = try await records.record(id: handle.id) else {
            throw AndroidCredentialVaultError.credentialNotFound(handle.id)
        }
        let reference = Self.reference(for: record.keychainAccount)
        do {
            guard let secret = try await gateway.read(reference: reference) else {
                throw AndroidCredentialVaultError.secretMissing(handle.id)
            }
            return secret
        } catch let error as AndroidCredentialVaultError {
            throw error
        } catch {
            throw AndroidCredentialVaultError.gatewayFailure(
                operation: .read, kind: Self.failureKind(for: error))
        }
    }

    /// Honest local-only status. This never reads secret bytes and never
    /// reports `.synced`, `.syncing` or cloud readiness.
    public func status(_ handle: CredentialHandle) async throws -> AndroidCredentialSyncStatus {
        try Task.checkCancellation()
        let record = try await records.record(id: handle.id)
        guard record != nil else {
            throw AndroidCredentialVaultError.credentialNotFound(handle.id)
        }
        return .syncUnavailable
    }

    // MARK: Deletion / durable queue

    /// Deletes metadata first; the original BEFORE DELETE trigger enqueues
    /// the account in the original durable `credential_deletion_queue`
    /// (INSERT OR IGNORE: an older claim generation re-validates the same
    /// row). That one account is then drained targeted under the SAME live
    /// lease: gateway delete only for a row whose revalidated observation
    /// still matches and has no live metadata reference; queue completion
    /// only after the authoritative effect, conditioned on the verified
    /// generation AND the no-live-metadata guard. A failure leaves the
    /// durable row for the service-owned restart retry. No full-array queue
    /// scan is performed.
    @discardableResult
    public func delete(_ handle: CredentialHandle) async throws -> CredentialDeletionOutcome {
        try Task.checkCancellation()
        try beginHandleGuard(handle.id)
        defer { coordinator.endHandle(handle.id) }

        let preRead = try await records.record(id: handle.id)
        guard let preReadAccount = preRead?.keychainAccount else {
            // Nothing existed: no intent can belong to this handle and no
            // secret is owed. The broad drain is deliberately NOT triggered
            // here (CV-M3: no unbounded preflights per call). No account
            // means no lease and no durable effect is possible.
            do {
                try await records.delete(id: handle.id)
            } catch {
                throw AndroidCredentialVaultError.metadataDeleteFailed(handle.id)
            }
            return CredentialDeletionOutcome(metadataExisted: false, secretCleanup: .completed)
        }

        let (lease, receipt) = try await beginOwnedAccountOperation(preReadAccount, kind: .delete)
        defer { settleOwnedOperation(receipt: receipt, lease: lease) }

        // Authoritative re-read under the live lease: the account cannot be
        // re-registered mid-flight by any supported operation while this
        // lease is current (CV-R1).
        let existing = try await records.record(id: handle.id)
        let account = existing?.keychainAccount ?? preReadAccount
        do {
            try await records.delete(id: handle.id)
        } catch {
            throw AndroidCredentialVaultError.metadataDeleteFailed(handle.id)
        }
        _ = await drainAccountIntent(account: account, under: lease)
        let cleanup: CredentialSecretCleanup
        do {
            cleanup = try await queueRow(account: account) == nil ? .completed : .pendingDurableQueue
        } catch {
            cleanup = .unknown
        }
        return CredentialDeletionOutcome(metadataExisted: existing != nil, secretCleanup: cleanup)
    }

    /// Crash-recoverable cleanup over the ORIGINAL `credential_deletion_queue`
    /// — the rows come either from the original SQLite BEFORE DELETE cascade
    /// trigger or from a vault capture claim that a process death left behind.
    ///
    /// The whole drain runs under ONE real `.vaultMaintenance` registry
    /// receipt; every row additionally needs its own current recovery lease
    /// (non-blocking): an account with a LIVE owner is skipped, never
    /// treated as a crash orphan (CV-R1). The decision per row is made in
    /// one original writer transaction against the live original metadata
    /// with the observed row REVALIDATED (CV-R2); the gateway delete happens
    /// only for a revalidated cleanup-required observation; queue completion
    /// happens only after the authoritative effect, conditioned on the exact
    /// verified tuple AND the still-absent-metadata guard.
    ///
    /// Traversal is a bounded keyset cursor over the deterministic
    /// `(enqueued_at, keychain_account)` order with an explicit pass budget
    /// (CV-R3). Every count in the report is exact against SQL at call
    /// start/end; `truncatedBudget`/`remaining` honestly expose anything left
    /// for the next service-owned drain. Rows are never removed before the
    /// gateway delete is authoritative. Errors are stored as stable,
    /// redacted codes; underlying exception text is never persisted.
    @discardableResult
    public func drainDeletionQueue() async -> CredentialDeletionDrainReport {
        let pendingAtStart: Int
        do {
            pendingAtStart = try await pendingIntentCount()
        } catch {
            return .queryFailure()
        }
        if pendingAtStart == 0 {
            return CredentialDeletionDrainReport(
                pendingAtStart: 0, completed: 0, failed: 0, clearedObsolete: 0,
                skippedConcurrent: 0, truncatedBudget: false,
                remaining: 0, queryFailed: false)
        }
        // The REAL owned-work port fences the whole drain: attach BEFORE the
        // first durable side effect. A rejected attach (store not ready /
        // stop already requested) fails closed with zero effects — the
        // durable rows are simply still there for the next service drain.
        let receipt: String
        do {
            receipt = try attachOwnedWork()
        } catch let error as AndroidCredentialVaultError {
            switch error {
            case .ownedWorkAdmissionRejected(let code):
                return .ownedWorkRefused(code)
            case .ownedWorkAdmissionInvalidIdentity:
                return .ownedWorkRefused(.invalidOwnerToken)
            default:
                return .queryFailure()
            }
        } catch {
            return .queryFailure()
        }
        defer {
            _ = ownedWork.detachVaultMaintenance(
                receipt: receipt, epoch: identity.epoch, ownerID: coordinator.ownerID)
        }
        return await drainBody(pendingAtStart: pendingAtStart)
    }

    private func drainBody(pendingAtStart: Int) async -> CredentialDeletionDrainReport {
        var completed = 0
        var failed = 0
        var clearedObsolete = 0
        var skippedConcurrent = 0
        var truncatedBudget = false
        let limit = Self.cleanupBatchLimit
        // Strict, explicit work budget: the stored order is walked once per
        // call at batch granularity, plus two passes for rows re-enqueued
        // ahead of the cursor by authoritative cascades during the call.
        let maxPasses = max(1, (pendingAtStart + limit - 1) / limit) + 2
        // Keyset cursor (CV-R3): the exact (enqueued_at, account) of the
        // last VISITED row. Failed/skipped rows are never assumed to stay in
        // place — the cursor advances monotonically in the stored order and
        // each visited row is attempted at most once per call.
        var cursorAt = ""
        var cursorAccount = ""
        var passes = 0
        var reachedOrderEnd = false

        while passes < maxPasses {
            passes += 1
            let batch: [CredentialCleanupRow]
            do {
                batch = try await pendingIntentBatch(
                    limit: limit, afterAt: cursorAt, afterAccount: cursorAccount)
            } catch {
                let remaining: Int? = try? await pendingIntentCount()
                return CredentialDeletionDrainReport(
                    pendingAtStart: pendingAtStart, completed: completed, failed: failed,
                    clearedObsolete: clearedObsolete, skippedConcurrent: skippedConcurrent,
                    truncatedBudget: truncatedBudget,
                    remaining: remaining, queryFailed: true)
            }
            if batch.isEmpty { reachedOrderEnd = true; break }
            for row in batch {
                cursorAt = row.enqueuedAt
                cursorAccount = row.account
                guard let lease = coordinator.tryAcquireRecoveryLease(row.account) else {
                    // A LIVE operation owns this account (capture mid-write,
                    // delete mid-drain, …). Its claim is never an orphan and
                    // its effects are never stolen (CV-R1).
                    skippedConcurrent += 1
                    continue
                }
                let outcome = await processIntentRow(row, under: lease)
                coordinator.release(lease)
                switch outcome {
                case .gatewayDeleteCompleted:
                    completed += 1
                case .obsoleteCleared:
                    clearedObsolete += 1
                case .failed:
                    failed += 1
                case .skippedConcurrent:
                    skippedConcurrent += 1
                }
            }
            // A SHORT batch is NOT the end of the stored order: rows can be
            // removed (stale observations) and NEWER intents can be inserted
            // beyond the cursor while an effect is in flight (the cascade
            // trigger). Only an EMPTY batch proves the order ended; otherwise
            // the explicit pass budget bounds the call and `truncatedBudget`
            // reports anything left. Every visited row still advances the
            // cursor, so no row is attempted twice in one call and failures
            // cannot starve later rows.
        }
        // The loop exits either at the end of the stored order (empty or
        // short final batch) or by the explicit budget. Only the budget exit
        // can leave rows unvisited in THIS call; say so honestly.
        truncatedBudget = !reachedOrderEnd

        let remaining: Int?
        do {
            remaining = try await pendingIntentCount()
        } catch {
            return CredentialDeletionDrainReport(
                pendingAtStart: pendingAtStart, completed: completed, failed: failed,
                clearedObsolete: clearedObsolete, skippedConcurrent: skippedConcurrent,
                truncatedBudget: truncatedBudget, remaining: nil, queryFailed: true)
        }
        return CredentialDeletionDrainReport(
            pendingAtStart: pendingAtStart,
            completed: completed,
            failed: failed,
            clearedObsolete: clearedObsolete,
            skippedConcurrent: skippedConcurrent,
            truncatedBudget: truncatedBudget,
            remaining: remaining,
            queryFailed: false
        )
    }

    /// Explicit retry for a capture that failed after a secret write but never
    /// committed metadata. It runs under the shared coordinator's account
    /// lease and the real registry receipt; refuses when any metadata record
    /// with this id exists, and refuses unless the ORIGINAL queue still
    /// carries the durable owned intent for the canonical reference — public
    /// discard may never delete an arbitrary unregistered ref (Main finding
    /// CV-M1 boundary). The restart drain recovers the same state without any
    /// caller-retained id; this entry point is only the immediate in-process
    /// retry.
    public func discardUncommittedSecret(id: UUID) async throws {
        try Task.checkCancellation()
        try beginHandleGuard(id)
        defer { coordinator.endHandle(id) }
        let account = Self.keychainAccount(for: id)
        let (lease, receipt) = try await beginOwnedAccountOperation(account, kind: .discard)
        defer { settleOwnedOperation(receipt: receipt, lease: lease) }

        let existing = try await records.record(id: id)
        guard existing == nil else {
            throw AndroidCredentialVaultError.credentialConflict(id)
        }
        guard let intent = try await queueRow(account: account) else {
            throw AndroidCredentialVaultError.durableCleanupIntentMissing(id)
        }
        // The durable row plus the CURRENT lease proves this operation is the
        // live owner of the recovery decision; live metadata proves the
        // secret is REFERENCED (a restarted/re-registered credential may own
        // this account now). Discard then refuses instead of deleting a
        // committed credential through a stale intent.
        if try await hasLiveMetadata(account: account) {
            throw AndroidCredentialVaultError.credentialConflict(id)
        }
        let reference = Self.reference(for: account)
        do {
            try await gateway.delete(reference: reference)
        } catch {
            throw AndroidCredentialVaultError.gatewayFailure(
                operation: .delete, kind: Self.failureKind(for: error))
        }
        // Authoritative effect: finalize OUR verified generation only, under
        // the no-live-metadata guard.
        do {
            _ = try await finalizeAccountClaim(
                account: account,
                enqueuedAt: intent.enqueuedAt,
                requiresLiveMetadata: false)
        } catch {
            throw AndroidCredentialVaultError.metadataWriteFailed(id)
        }
    }

    // MARK: Durable claim helpers (narrow SQL over the ORIGINAL tables)

    /// Atomic claim for capture/register: targeted drain on an existing
    /// (durable-UNOWNED, because this lease is current and no supported
    /// operation can touch the account meanwhile) intent, and refusal around
    /// a still-pending one; conflict on live metadata. The claimed generation
    /// is recorded on the CURRENT lease so nested cleanup under this same
    /// lease never destroys the row being awaited (CV-R2).
    private func claimAccountForWrite(
        account: String,
        lease: VaultAccountLease,
        refusal: AndroidCredentialVaultError,
        pendingError: AndroidCredentialVaultError
    ) async throws -> String {
        switch try await claimAccount(account: account) {
        case .claimed(let enqueuedAt):
            coordinator.setClaimGeneration(lease, generation: enqueuedAt)
            return enqueuedAt
        case .metadataPresent:
            throw refusal
        case .intentPresent:
            _ = await drainAccountIntent(account: account, under: lease)
            switch try await claimAccount(account: account) {
            case .claimed(let enqueuedAt):
                coordinator.setClaimGeneration(lease, generation: enqueuedAt)
                return enqueuedAt
            case .metadataPresent:
                throw refusal
            case .intentPresent:
                throw pendingError
            }
        }
    }

    /// The one logical account claim: ONE original writer transaction checks
    /// the UNIQUE-indexed metadata account and the account-PK queue row and
    /// inserts the claim, then reads back its own generation. No second
    /// business DB, no persistent cursor outside the original queue, no RAM
    /// fallback. Closure is synchronous GRDB — nothing is awaited inside.
    private func claimAccount(account: String) async throws -> CredentialAccountClaim {
        try await database.writer { db in
            let metadataLive = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM credential_records WHERE keychain_account = ?
                    )
                    """,
                arguments: [account]) ?? false
            if metadataLive { return .metadataPresent }
            let intent = try String.fetchOne(
                db,
                sql: """
                    SELECT enqueued_at FROM credential_deletion_queue
                    WHERE keychain_account = ?
                    """,
                arguments: [account])
            if intent != nil { return .intentPresent }
            // Mirrors the original trigger's column/value semantics
            // (synchronizable 0, datetime('now'), last_error NULL) inside the
            // existing account-PK table. No schema change. The read-back
            // value is a second-resolution wall clock — an observation used
            // for conditional revalidation, never a unique generation
            // (CV-R2).
            try db.execute(
                sql: """
                    INSERT INTO credential_deletion_queue (
                        keychain_account, synchronizable, enqueued_at, last_error
                    ) VALUES (?, 0, datetime('now'), NULL)
                    """,
                arguments: [account])
            let generation = try String.fetchOne(
                db,
                sql: """
                    SELECT enqueued_at FROM credential_deletion_queue
                    WHERE keychain_account = ?
                    """,
                arguments: [account])
            guard let generation else {
                throw FloeError.storageCorrupted("Credential claim generation missing")
            }
            return .claimed(enqueuedAt: generation)
        }
    }

    /// Conditional queue completion: in ONE writer transaction re-check the
    /// ORIGINAL metadata truth against this operation's expectation and
    /// delete ONLY the exact observed (`keychain_account`, `enqueued_at`)
    /// row. The transaction returns 0 without deleting when the guard fails,
    /// which is the conservative direction: a newer legitimate intent (e.g.
    /// a cascade re-enqueue whose metadata is live again) survives for the
    /// next decision-table evaluation instead of being erased by a stale
    /// finalizer (CV-R2). Enforced serialization (the current lease held for
    /// the whole operation) is what makes a same-second reinsertion
    /// unreachable for SUPPORTED writers at all; the tuple condition is
    /// defense-in-depth, NOT a claim that the timestamp is a generation.
    /// One conditional queue removal in ONE writer transaction (see
    /// `finalizeAccountClaim`).
    private static func finalizeClaimRow(
        database: DatabaseManager,
        account: String,
        enqueuedAt: String,
        requiresLiveMetadata: Bool
    ) async throws -> Int {
        try await database.writer { db in
            let metadataLive = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM credential_records WHERE keychain_account = ?
                    )
                    """,
                arguments: [account]) ?? false
            guard metadataLive == requiresLiveMetadata else {
                return 0
            }
            try db.execute(
                sql: """
                    DELETE FROM credential_deletion_queue
                    WHERE keychain_account = ? AND enqueued_at = ?
                    """,
                arguments: [account, enqueuedAt])
            return db.changesCount
        }
    }

    @discardableResult
    private func finalizeAccountClaim(
        account: String,
        enqueuedAt: String,
        requiresLiveMetadata: Bool
    ) async throws -> Int {
        try await Self.finalizeClaimRow(
            database: database,
            account: account,
            enqueuedAt: enqueuedAt,
            requiresLiveMetadata: requiresLiveMetadata)
    }

    /// Failed-operation release: metadata must still be ABSENT (the truth
    /// this operation knows: it never committed metadata). If some other path
    /// re-registered live metadata meanwhile, the row is now an obsolete
    /// intent under the decision table and is deliberately left for that
    /// table instead of being erased here.
    ///
    /// Cancellation-surviving: this runs only AFTER the effect is settled
    /// (a successful compensating delete or a proven no-effect write), and
    /// GRDB's async writer throws `CancellationError` on a cancelled task —
    /// a cancelled caller would otherwise silently leave its own claim row
    /// behind and block the account until the next service drain. The
    /// one-shot bookkeeping therefore runs in an unstructured task that does
    /// not inherit this task's cancellation. It is not a timer and creates
    /// no second owner; the row stays the recovery authority until this
    /// completes.
    private func releaseClaimQuietly(account: String, enqueuedAt: String) async {
        let database = self.database
        await Task.detached {
            _ = try? await Self.finalizeClaimRow(
                database: database,
                account: account,
                enqueuedAt: enqueuedAt,
                requiresLiveMetadata: false)
        }.value
    }

    // MARK: Bounded queue queries (CV-M3 + CV-R3)

    /// Targeted EXISTS over the UNIQUE-indexed metadata account column.
    private func hasLiveMetadata(account: String) async throws -> Bool {
        try await database.reader { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM credential_records WHERE keychain_account = ?
                    )
                    """,
                arguments: [account]) ?? false
        }
    }

    /// Targeted PK lookup of the durable intent row for ONE account.
    private func queueRow(account: String) async throws -> CredentialCleanupRow? {
        try await database.reader { db in
            guard let enqueuedAt = try String.fetchOne(
                db,
                sql: """
                    SELECT enqueued_at FROM credential_deletion_queue
                    WHERE keychain_account = ?
                    """,
                arguments: [account]) else { return nil }
            return CredentialCleanupRow(account: account, enqueuedAt: enqueuedAt)
        }
    }

    private func pendingIntentCount() async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM credential_deletion_queue") ?? 0
        }
    }

    /// Bounded keyset batch in deterministic `(enqueued_at,
    /// keychain_account)` order (CV-R3): rows strictly after the visited
    /// cursor, never OFFSET. `""`/`""` is the initial cursor and matches the
    /// whole table because every stored account/enqueued_at value is
    /// non-empty under the original schema. The queue carries only
    /// secret-free original metadata columns.
    private func pendingIntentBatch(
        limit: Int, afterAt cursorAt: String, afterAccount cursorAccount: String
    ) async throws -> [CredentialCleanupRow] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT keychain_account, enqueued_at FROM credential_deletion_queue
                    WHERE enqueued_at > ?
                       OR (enqueued_at = ? AND keychain_account > ?)
                    ORDER BY enqueued_at ASC, keychain_account ASC
                    LIMIT ?
                    """,
                arguments: [cursorAt, cursorAt, cursorAccount, limit])
                .map { row in
                    CredentialCleanupRow(
                        account: row["keychain_account"],
                        enqueuedAt: row["enqueued_at"])
                }
        }
    }

    // MARK: Intent processing (shared by full drain, targeted delete and
    //      capture/replace preflight)

    /// Process exactly one observed intent row UNDER THE CURRENT ACCOUNT
    /// LEASE. No awaited nested actor runs inside a DB transaction; the
    /// live-reference check and the row revalidation share ONE writer
    /// transaction, and the post-delete completion shares another.
    private func processIntentRow(
        _ row: CredentialCleanupRow,
        under lease: VaultAccountLease
    ) async -> CredentialIntentOutcome {
        // Lease currency is the ownership truth (CV-R1): the caller holds it
        // either as a recovery lease or as the mutation operation's own
        // lease. A stale lease never performs an effect.
        guard coordinator.isCurrent(lease) else { return .skippedConcurrent }
        // The lease holder's OWN in-flight claim row is never finalized or
        // cleaned through this path (the row it just inserted and is still
        // awaiting on).
        if coordinator.currentClaimGeneration(row.account) == row.enqueuedAt {
            return .skippedConcurrent
        }

        let decision: CredentialIntentDecision
        do {
            decision = try await database.writer { db in
                let metadataLive = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM credential_records WHERE keychain_account = ?
                        )
                        """,
                    arguments: [row.account]) ?? false
                if metadataLive {
                    try db.execute(
                        sql: """
                            DELETE FROM credential_deletion_queue
                            WHERE keychain_account = ? AND enqueued_at = ?
                            """,
                        arguments: [row.account, row.enqueuedAt])
                    return db.changesCount > 0 ? .liveMetadataCleared : .generationAdvanced
                }
                // CV-R2 stale-side-effect fix: even with NO live metadata
                // the decision transaction REVALIDATES that the observed row
                // still exists with the exact expected tuple. A vanished or
                // advanced row is NEVER gateway-deleted on the stale
                // observation; the next drain decides on the fresh truth.
                let observedNow = try String.fetchOne(
                    db,
                    sql: """
                        SELECT enqueued_at FROM credential_deletion_queue
                        WHERE keychain_account = ?
                        """,
                    arguments: [row.account])
                guard observedNow == row.enqueuedAt else {
                    return .generationAdvanced
                }
                return .cleanupRequired
            }
        } catch {
            return .failed
        }

        switch decision {
        case .liveMetadataCleared:
            return .obsoleteCleared
        case .generationAdvanced:
            return .skippedConcurrent
        case .cleanupRequired:
            break
        }

        // The lease is still current and the observation was just
        // revalidated inside the writer; the effect below is owed.
        let reference = Self.reference(for: row.account)
        do {
            try await gateway.delete(reference: reference)
        } catch {
            let failure = Self.failureKind(for: error)
            try? await recordIntentFailure(
                account: row.account,
                message: Self.deletionFailureMessage(failure))
            return .failed
        }

        // Only now, after the authoritative effect, complete the exact
        // generation that was verified as cleanup-required — conditioned in
        // one final writer transaction on the metadata STILL being absent (a
        // live metadata reference here means the row's truth changed: the
        // row is left for the decision table; the canonical reference was
        // already authoritatively deleted and account↔reference is 1:1 by
        // construction, so no secret is lost and no legitimate intent is
        // silently erased).
        do {
            let removed = try await finalizeAccountClaim(
                account: row.account,
                enqueuedAt: row.enqueuedAt,
                requiresLiveMetadata: false)
            if removed > 0 {
                return .gatewayDeleteCompleted
            }
            // Either the exact row vanished (another finalizer of the same
            // verified generation within this shared coordinator) or the
            // metadata-live guard deferred it. The gateway effect for THIS
            // observation is achieved either way; a deferred row is honestly
            // re-decided on the next pass (the exact `remaining` count covers
            // it).
            return .gatewayDeleteCompleted
        } catch {
            try? await recordIntentFailure(
                account: row.account,
                message: "gateway deletion succeeded; queue bookkeeping failed")
            return .failed
        }
    }

    /// Targeted single-account drain used by delete/capture/replace before
    /// deciding a pending-intent refusal. It runs under the CALLER's current
    /// lease (no nested acquisition, no second receipt): the row observed
    /// here provably belongs to a SETTLED prior owner (this lease's own
    /// claim, if any, is a different row guarded inside
    /// `processIntentRow`).
    @discardableResult
    private func drainAccountIntent(
        account: String, under lease: VaultAccountLease
    ) async -> CredentialIntentOutcome? {
        guard let row = try? await queueRow(account: account) else { return nil }
        return await processIntentRow(row, under: lease)
    }

    /// Replace-preflight: if a durable intent exists, attempt its targeted
    /// completion under the caller's lease; refuse while one persists.
    /// Targeted PK lookup only — the full-array `pendingDeletions()`
    /// preflight is gone (CV-M3).
    private func ensureAccountDrainedOrRefused(
        account: String, handleID: UUID, under lease: VaultAccountLease
    ) async throws {
        if try await queueRow(account: account) != nil {
            _ = await drainAccountIntent(account: account, under: lease)
            if try await queueRow(account: account) != nil {
                throw AndroidCredentialVaultError.referenceCleanupPending(handleID)
            }
        }
    }

    /// Stable, redacted failure bookkeeping mirroring the original
    /// `CredentialStore.recordDeletionFailure` semantics (SecretRedactor
    /// applied, `enqueued_at` untouched so the conditional completion stays
    /// valid). Narrow UPDATE over the existing table.
    private func recordIntentFailure(account: String, message: String) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    UPDATE credential_deletion_queue SET last_error = ?
                    WHERE keychain_account = ?
                    """,
                arguments: [SecretRedactor.redact(message), account])
        }
    }

    // MARK: Private helpers

    private static func validate(_ secret: Data) throws {
        guard !secret.isEmpty,
              secret.count <= SecretGatewayLimits.maximumSecretBytes else {
            throw AndroidCredentialVaultError.invalidSecret
        }
    }

    private static func keychainAccount(for id: UUID) -> String {
        "credential.\(id.uuidString)"
    }

    private static func reference(for keychainAccount: String) -> String {
        SecretGatewayNaming.opaqueReference(
            namespace: referenceNamespace, account: keychainAccount)
    }

    /// Metadata account of an existing record. The authoritative truth is
    /// re-read inside the account lease.
    private func accountOfRecord(_ id: UUID) async throws -> String {
        guard let record = try await records.record(id: id) else {
            throw AndroidCredentialVaultError.credentialNotFound(id)
        }
        return record.keychainAccount
    }

    /// One compensating attempt. The caller reports success/failure; no error
    /// text is retained. A failed compensation deliberately keeps the
    /// durable claim row instead (CV-M1 recovery authority).
    private func deleteSecret(reference: String) async -> Bool {
        do {
            try await gateway.delete(reference: reference)
            return true
        } catch {
            return false
        }
    }

    /// CV-R4 classification over the ACTUAL frozen gateway error surface.
    /// Source-proven emission sites (SecretGatewayMailbox.swift, pinned
    /// b46d37ee…):
    ///   * `mailboxSaturated` / `backendBusy` / `invalidReference` /
    ///     `invalidValue` / `intentRejected` — emitted ONLY by
    ///     `makeTicket`/`publish`/the ingress validator BEFORE any ticket is
    ///     queued (lines 271..315 plus the closed intent policy): the store
    ///     can never have received the request ⇒ provable `.rejected`.
    ///   * `dispatcherUnresponsive` — emitted BOTH pre-queue (lines 295/301)
    ///     AND by the watchdog for tickets ALREADY IN `.claimed` state
    ///     (lines 923..934: state → `callerSettledExecutionOutstanding`,
    ///     permit/effect-unknown retained). The SAME enum therefore is NOT
    ///     proof of no effect ⇒ conservatively `.effectUnknown` (Main
    ///     VAULT_GATEWAY_FAILURE_SEMANTICS_MAIN_20261019.json): never a
    ///     durable-claim release on this error alone; compensation-then-truth
    ///     decides, and anything unproven keeps the durable intent.
    ///   * Everything else (`dispatcherCancelled`, `gatewayClosed`,
    ///     `dispatcherReplaced`, `quarantined`, `abandoned`, storage/keystore
    ///     families, `internal`) may cross the store boundary ⇒
    ///     `.effectUnknown` (unchanged from the parent).
    /// Final authority for the mailbox's own emission-site assumptions
    /// remains the pending gateway qualifier (job-cd5b38d6b6204b13); this
    /// mapping follows the reviewed source exactly and invents NO new backend
    /// enum anywhere.
    ///
    /// Compensation authority (for the `.effectUnknown` write path) traces
    /// the ACTUAL production ordering, not speculation: the frozen Kotlin
    /// `AndroidKeystoreCredentialStore.kt` (7d46d19b…) uses a process-shared
    /// SINGLE I/O executor with per-record locks and freezes bytes before
    /// dispatch, and `SecretGatewayDispatcher.kt` (99019029…) validates the
    /// native `isLive` gate before launching `activeStore.write` UNDISPATCHED
    /// and `runChild` awaits the actual store effect before completing the
    /// caller. A compensating `delete` for the same record therefore
    /// serializes behind any already-queued write on that record's lane, and
    /// its authoritative completion is real quiescence for THAT traced path.
    /// Where quiescence cannot be proven (the compensating delete itself
    /// failed), the durable intent and typed pending remain — never a fake
    /// compensation success.
    private static func failureKind(for error: Error) -> CredentialGatewayFailureKind {
        if error is CancellationError { return .effectUnknown }
        if let gatewayError = error as? SecretGatewayError {
            switch gatewayError {
            case .needsConfiguration:
                return .unavailable
            }
        }
        if let backendError = error as? SecretBackendError {
            switch backendError {
            case .invalidReference, .invalidValue, .mailboxSaturated, .backendBusy:
                // Source-proven pre-queue emissions only (see above).
                return .rejected
            case .intentRejected(_):
                return .rejected
            case .dispatcherUnresponsive:
                // CV-R4: the same enum also settles ALREADY-CLAIMED work
                // (watchdog lines 923..934). Never proof of no effect.
                return .effectUnknown
            default:
                // Includes dispatcherCancelled (-11/-13 are indistinguishable
                // in the Swift error), gatewayClosed, dispatcherReplaced,
                // abandoned, quarantined, storageFailure and internal.
                return .effectUnknown
            }
        }
        return .effectUnknown
    }

    private static func deletionFailureMessage(
        _ failure: CredentialGatewayFailureKind
    ) -> String {
        switch failure {
        case .unavailable: return "gateway unavailable"
        case .rejected: return "gateway rejected deletion"
        case .effectUnknown: return "gateway deletion outcome unknown"
        }
    }
}
