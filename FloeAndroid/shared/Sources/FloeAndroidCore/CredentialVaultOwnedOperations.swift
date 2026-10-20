// SPDX-License-Identifier: MPL-2.0
//
// Credential vault owned-operation lifetime + trusted runtime ownership
// context (G02 RB-2b owned-operations source candidate, job-07f0d672e3854e17).
//
// WHY THIS FILE EXISTS (Main findings CV-R1/CV-R2, 2026-10-19):
//   The recovery candidate (job-06f6addd2fdb4271) kept its live-operation
//   guards (`accountsInFlight` / `accountsDraining` / `mutationsInFlight`) as
//   RAM state INSIDE one vault actor. A capture therefore held its claim from
//   a DIFFERENT gate set than the drain: the same actor's startup drain could
//   treat a live capture's durable claim as a crash orphan and delete the
//   secret mid-flight, and a second vault over the same `DatabaseManager`
//   had wholly separate gates that silently bypassed the first. Durable
//   queue rows alone cannot coordinate LIVE operations because
//   `enqueued_at` is `datetime('now')` second-resolution wall clock — it is
//   an observation, NOT a unique operation generation (CV-R2;
//   MAIN_SQL_COUNTEREXAMPLES_20261019.py reproduced the same-second ABA on
//   the extracted original V11 DDL).
//
// WHAT THIS IS:
//   ONE narrow coordinator shared by EVERY vault wrapper admitted for the
//   SAME trusted runtime context (exact normalized root path + full owner
//   token + epoch, consumed verbatim from RB1's `RuntimeOwnerIdentity` — the
//   full identity, never the 4-byte diagnostic fingerprint, never model
//   JSON). It owns:
//     * per-handle double-start rejection (replaces the per-actor sets),
//     * per-account operation leases held across EVERY awaited gateway
//       completion, metadata truth resolution and queue bookkeeping —
//       including cancellation and error paths (release only happens after
//       the operation has actually settled; there is no timer and no
//       elapsed-time release anywhere in this file or in the vault),
//     * live-vs-retired ownership distinction: an account lease exists ONLY
//       while the owning operation is live. Admission for a newer epoch is
//       refused while ANY lease/waiter/handle is live (the retirement fence;
//       in production RB1's stop already waits for the real
//       `RuntimeOwnedWorkRegistry` count to reach zero, and vault
//       operations detach only at actual completion), so a new owner is
//       admitted only after the prior ownership is provably retired. On a
//       real process restart the RAM coordinator simply does not exist;
//       the durable ORIGINAL `credential_deletion_queue` rows stay the
//       recovery authority (no caller-retained UUID).
//
// COMPOSITION WITH THE ACTUAL RB1 PORT (Main guidance 2026-10-19):
//   `VaultOwnedWorkAttaching` mirrors the closed synchronous surface of the
//   real `RuntimeOwnedWorkRegistry.shared.attach(epoch:kind:ownerID:)` /
//   `detach(_:)` / `isAttached(_:)` (runtime-bootstrap-main-reviewed-source,
//   RuntimeFacadeBootstrap.swift lines 1047..1245; kind `vaultMaintenance`).
//   The production default `RuntimeOwnedWorkRegistryAttachment` forwards to
//   the shared registry unchanged — it is the ACTUAL lifecycle port, not an
//   unconnected counter and never a default fake zero. Attach happens
//   immediately BEFORE the first durable side effect of an owned operation
//   and detach only AFTER that operation's final queue bookkeeping; a mere
//   caller cancellation, resume or UI teardown never detaches while the real
//   effect can still complete. RB1's stop path drains this registry
//   (`waitForDrain`) and refuses new attaches (`ownedWorkAttachAllowed`) —
//   the vault then fails closed with typed admission errors instead of
//   inventing a parallel fence.
//
// LOCKING DISCIPLINE (Swift 6): the coordinator is a plain class behind an
// NSLock, mirroring the frozen `SecretGatewayRegistry` and the reviewed
// `RuntimeOwnedWorkRegistry` pattern. Every public method is synchronous and
// touches NO database and NO gateway; continuations are collected under the
// lock and resumed AFTER unlocking. Admission state is a separate lock and
// the two locks are never nested. No `await` occurs while any lock is held.
//
// ACTUAL QUALIFICATION STATUS (job-8f565e1e6c6a4e2a, 2026-10-20): published
// into the live `FloeAndroid/shared` overlay after the accepted GW/P0/RB1
// foundations, host-compiled and host-tested. The RB1 types it consumes
// (`RuntimeOwnerIdentity`, `RuntimeFacadeCode`, `RuntimeOwnedWorkRegistry`,
// `RuntimeOwnedWorkKind`, `RuntimeOwnedWorkToken`) are the published reviewed
// sources; the physical-settlement seam consumes the Main-accepted
// `PhysicalObservingSecretGateway` / `PhysicalOperationReceipt` API from
// `CredentialBackend.swift`/`SecretGatewayMailbox.swift` (model host
// qualification job-059dc09dd7bd48f1).
import Foundation
import FloePersistence

// MARK: - Owned-work attach port (composes the actual RB1 registry)

/// Closed result vocabulary mirroring `RuntimeOwnedWorkAttachOutcome`.
public enum VaultOwnedWorkAttach: Sendable, Equatable {
    /// The real registry accepted the work; carries the exact receipt.
    case attached(receipt: String)
    /// Typed rejection (`.notInstalled`, `.alreadyDraining`,
    /// `.domainNotBound`, `.receiptSaturated`, …). The operation must fail
    /// closed BEFORE any durable side effect.
    case rejected(RuntimeFacadeCode)
    /// The owner identity is structurally invalid (opaque, no path/secret).
    case invalidIdentity
}

/// The narrow synchronous surface the vault needs from the actual
/// `RuntimeOwnedWorkRegistry`. Tests supply a synthetic double with the SAME
/// contract; production uses `RuntimeOwnedWorkRegistryAttachment`.
public protocol VaultOwnedWorkAttaching: Sendable {
    func attachVaultMaintenance(epoch: UInt64, ownerID: String) -> VaultOwnedWorkAttach
    func detachVaultMaintenance(receipt: String, epoch: UInt64, ownerID: String) -> Bool
    func isVaultMaintenanceAttached(receipt: String, epoch: UInt64, ownerID: String) -> Bool
}

/// THE production port: forwards to the real shared
/// `RuntimeOwnedWorkRegistry` with kind `.vaultMaintenance`. The token
/// `detach`/`isAttached` receive is the exact value-equal reconstruction of
/// the attached token (the registry compares the whole `RuntimeOwnedWorkToken`
/// value, so a foreign receipt or drifted epoch/owner fails and never mutates
/// a newer generation — RB1-R3 exact-token semantics preserved).
public struct RuntimeOwnedWorkRegistryAttachment: VaultOwnedWorkAttaching {
    public static let shared = RuntimeOwnedWorkRegistryAttachment()
    public let registry: RuntimeOwnedWorkRegistry

    public init(registry: RuntimeOwnedWorkRegistry = .shared) {
        self.registry = registry
    }

    public func attachVaultMaintenance(
        epoch: UInt64, ownerID: String
    ) -> VaultOwnedWorkAttach {
        switch registry.attach(epoch: epoch, kind: .vaultMaintenance, ownerID: ownerID) {
        case .attached(let token):
            return .attached(receipt: token.receipt)
        case .rejected(let code):
            return .rejected(code)
        case .invalidIdentity:
            return .invalidIdentity
        }
    }

    public func detachVaultMaintenance(
        receipt: String, epoch: UInt64, ownerID: String
    ) -> Bool {
        let token = RuntimeOwnedWorkToken(
            receipt: receipt, epoch: epoch,
            kind: .vaultMaintenance, ownerID: ownerID)
        return registry.detach(token)
    }

    public func isVaultMaintenanceAttached(
        receipt: String, epoch: UInt64, ownerID: String
    ) -> Bool {
        let token = RuntimeOwnedWorkToken(
            receipt: receipt, epoch: epoch,
            kind: .vaultMaintenance, ownerID: ownerID)
        return registry.isAttached(token)
    }
}

// MARK: - Account leases + handle guards (shared by every admitted wrapper)

/// The scoped operation token for ONE account mutation (CV-R2 "actual scoped
/// operation token"): equality is the pre-minted operation identity, and the
/// coordinator refuses every effect path of a NON-current lease. It carries
/// no secret, no path and no wall-clock generation.
public struct VaultAccountLease: Sendable, Equatable, Hashable {
    public let account: String
    public let operationID: UUID

    /// The queue `enqueued_at` value read back for THIS operation's own
    /// claim row, maintained by the coordinator while the lease is current.
    /// `nil` for a lease that never minted a claim (delete/replace/discard)
    /// and for a settled (possibly re-minted) lease. Never treat this as an
    /// operation generation by itself — it is a second-resolution wall clock
    /// (CV-R2); its only role is the safety rule "never finalize/clean the
    /// row that the CURRENT live owner minted and is still awaiting".
    public internal(set) var claimGeneration: String?
}

/// Coordinator errors. The vault maps these onto its public
/// `AndroidCredentialVaultError` vocabulary, so the public error surface
/// stays stable.
public enum CredentialVaultCoordinationError: Error, Equatable, Sendable {
    case operationInFlight(UUID)
    case cancelledWhileWaiting
}

/// ONE explicit long-lived pending physical owner (CV-R4 actual-mailbox
/// binding). This is the supported honest end state when a caller was
/// resumed (mailbox watchdog) or cancelled while the individual backend
/// execution may still land: the account lease and the REAL
/// `.vaultMaintenance` receipt STAY ATTACHED to the live work, and the exact
/// attempt witness is retained so reconciliation settles ONLY on this
/// operation's individual physical truth (never the current registry, never
/// a global counter, never the durable row alone, never a timer). Runtime
/// only; carries no secret, no path and no model authority.
public struct CredentialVaultPendingPhysicalOwner: Sendable {
    /// Metadata account (also the lease key).
    public let account: String
    /// The CURRENT account lease this owner still holds.
    public let lease: VaultAccountLease
    /// The exact RB1 owned-work receipt that stays attached until settlement.
    public let registryReceipt: String
    /// The exact mailbox claim of the observed secret WRITE.
    public let claim: Int64
    /// The exact mailbox claim of the compensating DELETE when it was
    /// already initiated; `nil` when compensation has not been attempted.
    public var compensationClaim: Int64?
    /// The EXACT attempt-time observer that minted `claim`. A pending owner
    /// never consults the mutable registry for the truth of its own
    /// operation.
    public let witness: any PhysicalObservingSecretGateway
    /// The durable claim row this owner is still responsible for.
    public let enqueuedAt: String
    /// Canonical opaque reference (ASCII, no secret) for compensation.
    public let reference: String
}

/// Exact singleflight reconciliation reservation for ONE parked owner. Taken
/// in the SHARED coordinator before any await or side effect; only the holder
/// may adopt a compensation claim or settle the owner. A second reconciler
/// (another vault actor over the same context, or a reentrant call) observes
/// nil and performs no effect.
public struct PendingReconciliationLease: Sendable, Hashable {
    public let account: String
    public let operationID: UUID
    public let reservationID: UUID
}

/// One coordinator per admitted runtime context; shared by every vault
/// wrapper over that context. Synchronous, NSLock-guarded; NO database or
/// gateway access happens under the lock.
public final class CredentialVaultOperationCoordinator: @unchecked Sendable {
    /// Which supported operation currently owns the account lease. Kept for
    /// honest diagnostics only — coordination treats every kind equally.
    public enum LeaseKind: String, Sendable {
        case capture
        case replace
        case register
        case delete
        case discard
        case recoveryDrain
    }

    /// Opaque per-context domain identity for the owned-work registry
    /// (`RuntimeOwnedWorkRegistry` contract: never a path, token or secret).
    public let ownerID: String
    /// The admitted epoch this context coordinates (diagnostics only; the
    /// attach calls pass the vault's live identity epoch verbatim).
    public let epoch: UInt64
    /// The one `DatabaseManager` this context was bound to at admission.
    public let databaseID: ObjectIdentifier

    private let lock = NSLock()
    private var leases: [String: VaultAccountLease] = [:]
    private var waiters: [String: [Waiter]] = [:]
    private var handlesInFlight: Set<UUID> = []
    /// Explicit long-lived pending physical owners keyed by account (CV-R4
    /// actual-mailbox binding). A parked owner KEEPS its account lease and
    /// its registry receipt until reconciliation observes the real
    /// individual terminal truth — the durable queue row is never treated as
    /// settlement and the owner is never dropped merely because the caller
    /// was resumed by the watchdog or cancelled.
    private var pendingPhysical: [String: CredentialVaultPendingPhysicalOwner] = [:]

    /// Singleflight reconciliation reservations, keyed by account. A parked
    /// owner may be reconciled by ANY vault wrapper sharing this coordinator,
    /// and actors are reentrant: without a reservation two reconcilers can
    /// both snapshot the same owner and independently issue an old
    /// compensating delete. The reservation is taken BEFORE any await/side
    /// effect and is the ONLY authority to adopt claims or settle the owner.
    private struct PendingReconciliation {
        let operationID: UUID
        let reservationID: UUID
    }
    private var pendingReconciliations: [String: PendingReconciliation] = [:]

    /// Test-only deterministic scheduling seam for the cancellation /
    /// registration race (see `acquireAccount`). Production never installs
    /// it; it is instance-scoped so no global mutable state exists.
    private var registrationInterposer: (@Sendable (String) -> Void)?

    /// Test-only observation seam for the controlled two-reconciler overlap.
    private var reconciliationProbe: (@Sendable (String, Bool) -> Void)?

    private struct Waiter {
        let operationID: UUID
        let kind: LeaseKind
        let continuation: CheckedContinuation<VaultAccountLease, any Error>
    }

    /// One `acquireAccount` registration/cancellation handshake. Every state
    /// mutation happens under the coordinator lock, which makes "cancelled
    /// before registration" and "cancelled while registered" atomic with the
    /// registration itself.
    private final class AcquireRegistration: @unchecked Sendable {
        enum State {
            /// The registration closure has not run yet.
            case pending
            /// The waiter is enqueued and owned by the FIFO queue.
            case registered
            /// Cancellation won before registration: the closure must resume
            /// with the typed cancellation instead of enqueueing.
            case cancelled
            /// A terminal grant/removal already owns the continuation.
            case settled
        }
        var state: State = .pending
    }

    init(epoch: UInt64, databaseID: ObjectIdentifier) {
        self.epoch = epoch
        self.databaseID = databaseID
        self.ownerID = UUID().uuidString
    }

    // MARK: Handle double-start guard (per-handle `operationInFlight`)

    public func beginHandle(_ id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !handlesInFlight.contains(id) else {
            throw CredentialVaultCoordinationError.operationInFlight(id)
        }
        handlesInFlight.insert(id)
    }

    public func endHandle(_ id: UUID) {
        lock.lock()
        handlesInFlight.remove(id)
        lock.unlock()
    }

    // MARK: Account leases

    /// Mutation entry (capture/replace/register/delete/discard): FIFO wait
    /// for the account. Waits are cancellation-safe: a cancelled waiter is
    /// removed and resumed with `.cancelledWhileWaiting`; a lease granted to
    /// an already-cancelled caller is released immediately (checked after
    /// every wake). There is deliberately no timeout: an active operation's
    /// ownership ends ONLY when the operation itself settles.
    ///
    /// CV-R1 cancellation/registration repair (Main follow-up, 2026-10-19):
    /// the parent version checked `Task.isCancelled` and then registered the
    /// waiter in a LATER, unsynchronized step. Cancellation landing inside
    /// that window ran `onCancel` against an EMPTY queue (`cancelWaiter`
    /// found no exact waiter and returned), after which the registration
    /// queued the ALREADY-CANCELLED caller behind an indefinite active
    /// operation. The handshake below closes the window atomically: the
    /// cancellation handler and the registration closure mutate the SAME
    /// `AcquireRegistration.state` under the SAME coordinator lock, so
    /// exactly one of them owns the continuation:
    ///   * cancellation first → state `.cancelled`; registration resumes
    ///     immediately with the typed cancellation and NEVER enqueues;
    ///   * registration first → state `.registered`; cancellation removes the
    ///     exact waiter (by pre-minted operation identity) and resumes it;
    ///   * grant raced cancellation → the FIFO release owns the continuation
    ///     and the post-wake check releases the granted lease (existing rule).
    /// No resumption can be lost or duplicated, and no tombstone/map entry
    /// survives: `.cancelled`/`.settled` are per-call objects collected with
    /// the call.
    public func acquireAccount(
        _ account: String, kind: LeaseKind
    ) async throws -> VaultAccountLease {
        if Task.isCancelled {
            throw CredentialVaultCoordinationError.cancelledWhileWaiting
        }
        // Supported deterministic seam for the exact original race schedule:
        // runs BETWEEN the cancellation check above and the atomic
        // registration below, where the parent defect lived. Never installed
        // by production code. The synchronous accessor performs the lock so
        // this async context never takes an NSLock directly.
        if let interposer = currentRegistrationInterposer() {
            interposer(account)
        }
        // Pre-mint the operation identity BEFORE queueing so the exact
        // waiter can be cancelled by identity (never "whatever is at the
        // tail"), which keeps FIFO grants and cancellation independent.
        let operationID = UUID()
        let registration = AcquireRegistration()
        let lease: VaultAccountLease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<VaultAccountLease, any Error>) in
                // Registration is atomic under the lock: either granted now
                // or queued. release() only touches already-registered
                // waiters, so no grant can be lost between these two paths.
                // Explicit NSLock discipline (frozen SecretGatewayRegistry
                // pattern) — no withLock availability assumptions.
                self.lock.lock()
                if case .cancelled = registration.state {
                    // Cancellation was observed before this closure ran: the
                    // caller must NOT be enqueued behind an active owner.
                    self.lock.unlock()
                    continuation.resume(
                        throwing: CredentialVaultCoordinationError.cancelledWhileWaiting)
                    return
                }
                var grantedNow: VaultAccountLease?
                if self.leases[account] == nil {
                    let lease = VaultAccountLease(
                        account: account,
                        operationID: operationID,
                        claimGeneration: nil)
                    self.leases[account] = lease
                    registration.state = .settled
                    grantedNow = lease
                } else {
                    self.waiters[account, default: []].append(
                        Waiter(
                            operationID: operationID,
                            kind: kind,
                            continuation: continuation))
                    registration.state = .registered
                }
                self.lock.unlock()
                if let grantedNow {
                    continuation.resume(returning: grantedNow)
                }
            }
        } onCancel: {
            self.lock.lock()
            switch registration.state {
            case .pending:
                // The registration closure has not run yet: flag the
                // handshake so it resumes with the typed cancellation
                // instead of enqueueing a cancelled waiter.
                registration.state = .cancelled
                self.lock.unlock()
            case .registered:
                registration.state = .settled
                var cancelled: CheckedContinuation<VaultAccountLease, any Error>?
                if var queue = self.waiters[account],
                   let index = queue.firstIndex(where: { $0.operationID == operationID }) {
                    let waiter = queue.remove(at: index)
                    if queue.isEmpty {
                        self.waiters[account] = nil
                    } else {
                        self.waiters[account] = queue
                    }
                    cancelled = waiter.continuation
                }
                self.lock.unlock()
                // A nil lookup means the FIFO release already dequeued and
                // now owns this continuation; the post-wake cancellation
                // check in `acquireAccount` releases that granted lease.
                cancelled?.resume(
                    throwing: CredentialVaultCoordinationError.cancelledWhileWaiting)
            case .cancelled, .settled:
                // Already terminal; exactly one owner resumed or will resume
                // the continuation.
                self.lock.unlock()
            }
        }
        // Conservative settle: a lease granted to an already-cancelled
        // caller is released immediately (the operation never starts, so no
        // durable effect and no registry receipt exist yet). This is not a
        // timer release: ownership ends only because the operation never
        // began.
        if Task.isCancelled {
            release(lease)
            throw CredentialVaultCoordinationError.cancelledWhileWaiting
        }
        return lease
    }

    /// Recovery entry (global drain row processing): NON-blocking. Returns
    /// nil while ANY live mutation or recovery lease owns the account — this
    /// is the CV-R1 fix: a live capture's claim is never treated as a crash
    /// orphan, and the inverse drain/mutation race uses the same gate.
    public func tryAcquireRecoveryLease(_ account: String) -> VaultAccountLease? {
        lock.lock()
        defer { lock.unlock() }
        guard leases[account] == nil else { return nil }
        let lease = VaultAccountLease(
            account: account, operationID: UUID(), claimGeneration: nil)
        leases[account] = lease
        return lease
    }

    /// Whether the account currently has a live owner (either direction).
    public func isAccountOwned(_ account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return leases[account] != nil
    }

    /// The live owner's own claim generation (nil when the holder never
    /// minted a claim row). Used by nested targeted cleanup so an operation
    /// NEVER finalizes its own still-in-flight claim row.
    public func currentClaimGeneration(_ account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return leases[account]?.claimGeneration
    }

    /// Records the generation of the claim row THIS lease just inserted
    /// (inside its claim transaction). Ignored for a stale lease.
    public func setClaimGeneration(_ lease: VaultAccountLease, generation: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard leases[lease.account]?.operationID == lease.operationID else { return }
        leases[lease.account]?.claimGeneration = generation
    }

    /// True while this exact lease is the current owner. Every queue/gateway
    /// effect path checks currency BEFORE the effect and before finalization.
    public func isCurrent(_ lease: VaultAccountLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return leases[lease.account]?.operationID == lease.operationID
    }

    /// Release at ACTUAL operation completion only (never on caller cancel
    /// while an awaited effect can still land: the operation settles first
    /// and only then calls this). Grants the next FIFO waiter.
    public func release(_ lease: VaultAccountLease) {
        var granted: (CheckedContinuation<VaultAccountLease, any Error>,
                      VaultAccountLease)?
        lock.lock()
        guard leases[lease.account]?.operationID == lease.operationID else {
            // A stale release (double release / foreign lease): never touch
            // the current owner.
            lock.unlock()
            return
        }
        leases[lease.account] = nil
        if var queue = waiters[lease.account], !queue.isEmpty {
            let waiter = queue.removeFirst()
            if queue.isEmpty {
                waiters[lease.account] = nil
            } else {
                waiters[lease.account] = queue
            }
            let replacement = VaultAccountLease(
                account: lease.account,
                operationID: waiter.operationID,
                claimGeneration: nil)
            leases[lease.account] = replacement
            granted = (waiter.continuation, replacement)
        }
        lock.unlock()
        // Continuations are resumed OUTSIDE the lock (reviewed mailbox /
        // registry discipline).
        if let granted {
            granted.0.resume(returning: granted.1)
        }
    }

    /// Diagnostics + the in-process retirement fence: true while any lease,
    /// waiter or handle mutation is live.
    public var hasLiveOperations: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !leases.isEmpty || !waiters.isEmpty || !handlesInFlight.isEmpty
            || !pendingPhysical.isEmpty
    }

    /// Counted for truthful diagnostics only (never readiness).
    public var liveOperationSummary: (accounts: Int, handles: Int, waiting: Int) {
        lock.lock()
        defer { lock.unlock() }
        let waiting = waiters.values.reduce(0) { $0 + $1.count }
        return (leases.count, handlesInFlight.count, waiting)
    }

    // MARK: - Explicit long-lived pending physical owners (CV-R4)

    /// Park ONE operation whose caller was resumed (watchdog / cancellation)
    /// while the real individual backend execution is still outstanding. The
    /// owner's lease remains CURRENT (so no newer operation can take the
    /// account and the retirement/rebind fences keep refusing) and the
    /// registry receipt stays attached; only reconciliation on the exact
    /// captured witness may settle it.
    public func parkPendingPhysical(_ owner: CredentialVaultPendingPhysicalOwner) {
        lock.lock()
        pendingPhysical[owner.account] = owner
        lock.unlock()
    }

    /// Bounded snapshot for reconciliation (deterministic account order).
    public func pendingPhysicalOwners() -> [CredentialVaultPendingPhysicalOwner] {
        lock.lock()
        defer { lock.unlock() }
        return pendingPhysical.values.sorted { $0.account < $1.account }
    }

    /// Whether this account currently has a parked physical owner.
    public func hasPendingPhysicalOwner(_ account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingPhysical[account] != nil
    }

    /// Take the EXACT singleflight reservation for one parked owner BEFORE
    /// any await or side effect. Returns nil when the owner is stale/foreign
    /// (its lease is no longer current) or another reconciler already holds
    /// the reservation — in which case this caller must perform NO effect.
    public func tryAcquirePendingReconciliation(
        _ owner: CredentialVaultPendingPhysicalOwner
    ) -> PendingReconciliationLease? {
        lock.lock()
        var outcome: PendingReconciliationLease?
        if pendingPhysical[owner.account]?.lease.operationID == owner.lease.operationID,
           leases[owner.account]?.operationID == owner.lease.operationID,
           pendingReconciliations[owner.account] == nil {
            let reservationID = UUID()
            pendingReconciliations[owner.account] = PendingReconciliation(
                operationID: owner.lease.operationID, reservationID: reservationID)
            outcome = PendingReconciliationLease(
                account: owner.account,
                operationID: owner.lease.operationID,
                reservationID: reservationID)
        }
        lock.unlock()
        // Observation for the controlled two-reconciler test happens OUTSIDE
        // the lock (the probe never participates in the decision).
        currentReconciliationProbe()?(owner.account, outcome != nil)
        return outcome
    }

    /// Cancellation/ownership handoff: drop the reservation WITHOUT settling
    /// or mutating the parked owner, so a later reconciliation may retry.
    /// Only the exact reservation holder can release it.
    public func releasePendingReconciliation(_ lease: PendingReconciliationLease) {
        lock.lock()
        if let current = pendingReconciliations[lease.account],
           current.reservationID == lease.reservationID {
            pendingReconciliations.removeValue(forKey: lease.account)
        }
        lock.unlock()
    }

    /// Adopt a NEWER compensation claim on the SAME exact parked owner. Only
    /// the current exact reservation holder may do so: a second reconciler
    /// can never take over or duplicate the old compensation.
    @discardableResult
    public func adoptCompensationClaim(
        _ owner: CredentialVaultPendingPhysicalOwner,
        claim: Int64,
        reservation: PendingReconciliationLease
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current = pendingReconciliations[owner.account],
              current.reservationID == reservation.reservationID,
              current.operationID == owner.lease.operationID,
              pendingPhysical[owner.account]?.lease.operationID == owner.lease.operationID else {
            return false
        }
        pendingPhysical[owner.account]?.compensationClaim = claim
        return true
    }

    /// Settle a parked owner EXACTLY ONCE under the exact reservation AND the
    /// exact lease identity. Removes the pending record and its reservation,
    /// then releases the account lease (granting the next FIFO waiter).
    /// Returns false for a stale/foreign/duplicate owner so no caller ever
    /// detaches a receipt that another reconciler already settled.
    @discardableResult
    public func settlePendingPhysical(
        _ owner: CredentialVaultPendingPhysicalOwner,
        reservation: PendingReconciliationLease
    ) -> Bool {
        lock.lock()
        guard let current = pendingReconciliations[owner.account],
              current.reservationID == reservation.reservationID,
              current.operationID == owner.lease.operationID,
              pendingPhysical[owner.account]?.lease.operationID == owner.lease.operationID,
              leases[owner.account]?.operationID == owner.lease.operationID else {
            lock.unlock()
            return false
        }
        pendingReconciliations.removeValue(forKey: owner.account)
        pendingPhysical.removeValue(forKey: owner.account)
        lock.unlock()
        release(owner.lease)
        return true
    }

    // MARK: - Test seam (never installed by product code)

    /// Deterministic scheduling seam for the cancellation-before-registration
    /// test: invoked with the account between `acquireAccount`'s initial
    /// cancellation check and its atomic registration.
    internal func setRegistrationInterposerForTesting(
        _ interposer: (@Sendable (String) -> Void)?
    ) {
        lock.lock()
        registrationInterposer = interposer
        lock.unlock()
    }

    /// Deterministic reservation/arrival observation seam for the controlled
    /// two-reconciler test: (account, reservationGranted). Never participates
    /// in any decision and is never installed by product code.
    internal func setReconciliationProbeForTesting(
        _ probe: (@Sendable (String, Bool) -> Void)?
    ) {
        lock.lock()
        reconciliationProbe = probe
        lock.unlock()
    }

    private func currentReconciliationProbe()
        -> (@Sendable (String, Bool) -> Void)?
    {
        lock.lock()
        defer { lock.unlock() }
        return reconciliationProbe
    }

    /// Synchronous lock-protected read (see the async-context NSLock rule).
    private func currentRegistrationInterposer() -> (@Sendable (String) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return registrationInterposer
    }
}

// MARK: - Trusted runtime ownership admission

/// Process-local admission state, one slot per EXACT normalized root path.
/// The equality rules deliberately mirror the reviewed RB1 admission
/// (RuntimeFacadeBootstrap lines 115..190): same full ownership = same root
/// path + FULL owner token (never the fingerprint), strictly newer epoch for
/// a replacement, and a hard fence against taking over while owned work is
/// live.
public enum CredentialVaultRuntimeAdmission {
    public enum Outcome: Sendable, Equatable {
        /// The caller joined the context that already owns this root
        /// (same full identity + same epoch + same bound DatabaseManager).
        case joinedSharedContext
        /// A NEW coordinator was created for this root.
        case admittedNewContext
        /// Fail-closed duplicate/incompatible ownership.
        case rejected(RuntimeFacadeCode)
    }

    private struct Slot {
        let token: String
        var epoch: UInt64
        var coordinator: CredentialVaultOperationCoordinator
    }

    private static let lock = NSLock()
    /// Process-local admission slots, guarded by `lock`. Swift 6 strict
    /// concurrency cannot prove the invariant across a static stored
    /// property; every read/write in this enum happens under `lock` (the
    /// frozen `SecretGatewayRegistry`/`RuntimeOwnedWorkRegistry` precedent).
    nonisolated(unsafe) private static var slots: [String: Slot] = [:]

    /// Admit (or join) one vault wrapper's coordinator.
    ///
    /// Rules:
    /// * no live slot for the exact root path → NEW context (bound to this
    ///   `DatabaseManager`);
    /// * full ownership match (root path + token) and SAME epoch and the same
    ///   bound manager → JOIN the existing coordinator (two vault wrappers
    ///   over one runtime/DB share ALL gates — the CV-R1 second-vault fix);
    /// * full ownership match and SAME epoch but a different physical
    ///   manager → `.epochNotNewer`: one lifecycle epoch owns exactly one
    ///   database handle (a reopened manager belongs to a newer lifecycle);
    /// * full ownership match and newer epoch: admitted ONLY when the prior
    ///   coordinator has provably NO live operations (leases/waiters/handles
    ///   empty) — the retirement fence. In production RB1 stop reaches this
    ///   only after `waitForDrain` proved every `vaultMaintenance` receipt
    ///   detached, and vault operations detach at actual completion, so "no
    ///   live operations" is the honest in-process mirror of "provably
    ///   retired previous ownership"; the durable queue rows left behind are
    ///   exactly the crash-restart recovery authority;
    /// * newer epoch while any operation is live → `.rebindWhileOwned`;
    /// * older epoch → `.epochNotNewer`;
    /// * different full owner under the same root path → `.ownerMismatch`
    ///   (never a silent takeover);
    /// * the same `DatabaseManager` already bound to a DIFFERENT root
    ///   context → `.lifecycleConflict` (two independent coordinators over
    ///   one physical DB is precisely the bug CV-R1 proved; the factory
    ///   makes it unrepresentable instead of merely discouraged).
    public static func admit(
        identity: RuntimeOwnerIdentity,
        database: DatabaseManager
    ) -> (outcome: Outcome, coordinator: CredentialVaultOperationCoordinator?) {
        let managerID = ObjectIdentifier(database)
        lock.lock()
        defer { lock.unlock() }
        if let slot = slots[identity.root.path] {
            guard slot.token == identity.token else {
                return (.rejected(.ownerMismatch), nil)
            }
            if identity.epoch == slot.epoch {
                guard slot.coordinator.databaseID == managerID else {
                    return (.rejected(.epochNotNewer), nil)
                }
                return (.joinedSharedContext, slot.coordinator)
            }
            guard identity.epoch > slot.epoch else {
                return (.rejected(.epochNotNewer), nil)
            }
            if slot.coordinator.hasLiveOperations {
                return (.rejected(.rebindWhileOwned), nil)
            }
            let replacement = CredentialVaultOperationCoordinator(
                epoch: identity.epoch, databaseID: managerID)
            slots[identity.root.path] = Slot(
                token: identity.token, epoch: identity.epoch,
                coordinator: replacement)
            return (.admittedNewContext, replacement)
        }
        // The manager may already be bound under a DIFFERENT root path.
        for slot in slots.values where slot.coordinator.databaseID == managerID {
            return (.rejected(.lifecycleConflict), nil)
        }
        let coordinator = CredentialVaultOperationCoordinator(
            epoch: identity.epoch, databaseID: managerID)
        slots[identity.root.path] = Slot(
            token: identity.token, epoch: identity.epoch, coordinator: coordinator)
        return (.admittedNewContext, coordinator)
    }

    /// In-process retirement of THIS wrapper's context: allowed only when
    /// the coordinator is the slot's current one and has no live
    /// operations. Removes the RAM gates; the durable original queue is
    /// never touched (it is the recovery authority for the next owner).
    /// Production retirement stays with RB1's stop receipt + registry drain;
    /// this is the same fence applied to the vault's own RAM state (used at
    /// test teardown and by a host that swaps lifecycle generations).
    public static func retire(
        identity: RuntimeOwnerIdentity,
        coordinator: CredentialVaultOperationCoordinator
    ) -> RuntimeFacadeCode? {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = slots[identity.root.path],
              slot.coordinator === coordinator,
              slot.epoch == identity.epoch else {
            return .notInstalled
        }
        guard !coordinator.hasLiveOperations else { return .alreadyDraining }
        slots[identity.root.path] = nil
        return nil
    }

    /// Test-only teardown (mirrors the reviewed registry's own
    /// `removeAllForTesting` precedent). Never called from product code.
    public static func removeAllForTesting() {
        lock.lock()
        slots.removeAll()
        lock.unlock()
    }
}
