// SPDX-License-Identifier: MPL-2.0
//
// RB2-REPAIR (job-ffa06be4f2d34ac4) — ProviderOperationCoordinator: the ACTUAL
// SHARED trusted-context provider operation coordination required by MC-R4
// (MAIN_SOURCE_REVIEW_20261019.json): "Build real shared trusted-root/epoch
// provider coordination (multiple facades same context coordinate/reject)
// with operation identity held across true effect/metadata lifetime.
// Samekind tokenless release cannot release later owner."
//
// Composition (no invented stand-ins):
// * The per-provider mutual-exclusion + pending-owner state machine lives
//   here, keyed by the ACTUAL shared database context (one DatabaseManager
//   instance = one trusted root context, the same instance-equality rule
//   Main's RB1 bootstrap uses for its single owned store). Two facades
//   constructed over the SAME DatabaseManager resolve the SAME coordinator
//   actor and therefore coordinate or reject — never two independent gates
//   for one provider id. This is the concrete replacement for the parent's
//   per-instance default, which Main's review explicitly rejected
//   ("not a dependency stall or default per-instance replacement at
//   runtime").
// * The epoch/trust fence stays where it is authoritative: the reviewed RB1
//   RuntimeOwnedWorkRegistry attach (ConfigOwnedWorkLifecycle). The
//   coordinator RETAINS the real registry lease token inside an unsettled
//   pending record, so root close (RB1: waits actual work / registry count
//   zero, stop timeout retains DB and root) genuinely waits the real owner.
//   There is NO timeout detach and no tokenless release.
// * Vault-owned-operations correction lane (job-07f0d672e3854e17) is
//   MAIN-REVIEW-PENDING (MAIN_SOURCE_REVIEW_20261019.json status
//   INTEGRITY_VERIFIED_CRITICAL_SOURCE_REVIEW_PENDING); its finalized
//   CredentialVaultOperationCoordinator API is therefore NOT yet a
//   consumable publication. Per the task rule ("consume actual finalized
//   API if present, otherwise provide concrete compatible provider
//   coordinator and explicit reconciliation seam") this type is authored
//   COMPATIBLE with that lane's delivered shape — (owner identity, epoch-
//   fenced attachment via the real registry, database-context instance
//   keying ObjectIdentifier, operation-identity leases, claim/generation
//   compare-before-release) — and exposes the explicit seam: Main may bind
//   any root/epoch-owned coordinator implementing ProviderOperationOwning
//   into ModelConfigurationFacade(ownership:) without touching this lane's
//   public typed outcomes. Accounts are disjoint BY CONSTRUCTION
//   (provider.<uuid> vs credential.*/host.*/approval-model); the vault
//   tool-vault queue (credential_records/V11) is never referenced here.
//
// Physical settlement is a SEPARATE axis (Models file
// SecretPhysicalAssessor): a pending record releases ONLY on the individual
// mailbox physical truth (neverDispatched / settled) or process restart with
// the durable ledger + drain reconciliation — never on a timer, the caller's
// error string alone, cancellation, or a durable-record-created event.
//
// MC-CAPACITY-1 repair (MAIN_SOURCE_REVIEW_20261019.json, this successor):
// the bounded reservation is taken atomically in `beginOperation` BEFORE any
// effect, covering running + pending as one per-operation budget; saturation
// is the new truthful `.capacityUnavailable` refusal (pre-effect, zero
// effects, no leaked receipt/lease/ticket), and `parkPending` for an exact
// running ticket always succeeds — a genuinely outstanding operation is
// never evicted, forgotten or stranded; it settles only on its own real
// physical completion.

import Foundation
import FloePersistence

// MARK: - Ticket identity

/// Exact owning identity for one reserved provider operation. Release must
/// present the SAME ticket (claimID): a stale or same-kind release can never
/// free a later owner (MC-R4 defect: "Samekind tokenless release cannot
/// release later owner").
public struct ProviderOperationTicket: Sendable, Hashable, Equatable {
    public let providerID: UUID
    public let kind: ProviderOperationKind
    public let claimID: UUID

    init(providerID: UUID, kind: ProviderOperationKind, claimID: UUID) {
        self.providerID = providerID
        self.kind = kind
        self.claimID = claimID
    }
}

public enum ProviderOperationBeginOutcome: Sendable, Equatable {
    case attached(ProviderOperationTicket)
    /// A live RUNNING operation holds the provider.
    case conflict
    /// A durable PENDING owner (unsettled physical lifetime) holds the
    /// provider. New operations must reconcile-or-wait; the facade runs ONE
    /// bounded reconciliation attempt before surfacing the typed refusal.
    case pendingReconciliation
    /// MC-CAPACITY-1 (MAIN_SOURCE_REVIEW_20261019.json): the bounded
    /// per-operation reservation is EXHAUSTED (running + pending == maximum).
    /// The refusal is delivered HERE — BEFORE any side effect — because the
    /// reservation is taken atomically at begin; nothing was queued, written
    /// or deleted, and no receipt/lease/ticket exists to leak. This is an
    /// additive enum case; every switch over this type must handle it
    /// (documented adapter delta, HANDOFF §2).
    case capacityUnavailable
}

/// The durable intent class a pending owner is holding the provider for.
/// Mirrors the cleanup-ledger intents exactly (no second vocabulary); the
/// ledger itself remains the only durable record.
public enum ProviderPendingIntent: String, Sendable, Equatable {
    case providerDelete
    case secretClear
    case secretWrite
}

/// One unsettled operation: operation identity + the RETAINED registry lease
/// + the individual physical receipt when available. `lease` retention is
/// what makes root-close genuinely wait the real owner.
///
/// `witness` (MC-OBSERVER-PENDING-OWNER, job-059dc09dd7bd48f1): the EXACT
/// observing gateway object that minted `receipt`, captured at attempt time.
/// Runtime-only, metadata-only, NEVER serialized or sent on any wire: the
/// reconciler must settle/acknowledge THIS receipt through THIS observer even
/// after the mutable registry is removed or re-pointed to a different
/// (possibly non-observing) gateway. A pending owner never consults the
/// CURRENT registry for the truth of an OLD operation.
public struct ProviderPendingRecord: Sendable {
    public let ticket: ProviderOperationTicket
    public let intent: ProviderPendingIntent
    public let receipt: PhysicalOperationReceipt?
    public let lease: ConfigOwnedWorkLease?
    public let witness: (any PhysicalObservingSecretGateway)?

    init(ticket: ProviderOperationTicket,
         intent: ProviderPendingIntent,
         receipt: PhysicalOperationReceipt?,
         lease: ConfigOwnedWorkLease?,
         witness: (any PhysicalObservingSecretGateway)? = nil) {
        self.ticket = ticket
        self.intent = intent
        self.receipt = receipt
        self.lease = lease
        self.witness = witness
    }
}

/// One bounded recovery-attempt holder per pending provider (prevents two
/// concurrent reconciliations racing the same signal).
public struct ProviderRecoveryLease: Sendable, Hashable {
    public let providerID: UUID
    public let leaseID: UUID
}

// MARK: - Shared coordinator

/// The production provider-operation coordinator for one shared database
/// context. Concrete real mutual exclusion (an actor-serialized state
/// machine), not an assumed vault-side guarantee and not a no-op.
public actor ProviderOperationCoordinator: ProviderOperationOwning {
    private enum Slot {
        case running(ProviderOperationTicket)
        case pending(ProviderPendingRecord, recoveryLeaseID: UUID?)
    }

    private var slots: [UUID: Slot] = [:]
    /// Bounded per-operation reservation guard (AGENTS.md bounded-buffers
    /// rule). MC-CAPACITY-1: the bound now covers TOTAL in-flight operations
    /// (running + pending — one reservation per operation), and it is
    /// enforced at `beginOperation` BEFORE any effect. The constant value
    /// (64) and name are preserved; what changed is only WHEN and HOW the
    /// bound refuses (truthfully, pre-effect, recoverably).
    public static let maximumPending = 64

    public init() {}

    /// Atomic per-operation reservation (MC-CAPACITY-1). The bounded slot is
    /// taken HERE — before the caller runs ANY effect — so a later
    /// `parkPending` for this exact ticket can NEVER fail on capacity: the
    /// reservation it needs is already its own. Saturation therefore surfaces
    /// as this typed pre-effect refusal instead of the parent's post-effect
    /// `parkPending == false` leak (running slot held forever, receipt/lease
    /// dropped from the pending record, reconciler blind).
    public func beginOperation(providerID: UUID,
                               kind: ProviderOperationKind) async
        -> ProviderOperationBeginOutcome
    {
        switch slots[providerID] {
        case .running:
            return .conflict
        case .pending:
            return .pendingReconciliation
        case nil:
            guard slots.count < Self.maximumPending else {
                return .capacityUnavailable
            }
            let ticket = ProviderOperationTicket(providerID: providerID,
                                                 kind: kind,
                                                 claimID: UUID())
            slots[providerID] = .running(ticket)
            return .attached(ticket)
        }
    }

    /// Exact-ticket release. A mismatched/foreign/stale ticket releases
    /// NOTHING (never another owner's slot; pending slots require
    /// settlePending with the pending record's own ticket).
    public func endOperation(_ ticket: ProviderOperationTicket) async {
        if case let .running(current)? = slots[ticket.providerID], current == ticket {
            slots.removeValue(forKey: ticket.providerID)
        }
    }

    /// Convert THIS running operation into the durable pending owner. The
    /// caller passes its OWN ticket; a mismatch is ignored (defense against
    /// a stale chain mis-parking a newer owner). Returns whether the park
    /// took effect.
    ///
    /// MC-CAPACITY-1: the reservation was taken at `beginOperation`, so an
    /// exact-ticket running slot ALWAYS parks — the exact receipt/ticket/
    /// root lease are retained in the pending record and the reconciler can
    /// settle the owner after REAL completion without a process restart.
    /// There is no post-effect capacity guard left to strand a completed
    /// operation.
    @discardableResult
    public func parkPending(_ ticket: ProviderOperationTicket,
                            intent: ProviderPendingIntent,
                            receipt: PhysicalOperationReceipt?,
                            lease: ConfigOwnedWorkLease?,
                            witness: (any PhysicalObservingSecretGateway)? = nil) async -> Bool
    {
        if case let .running(current)? = slots[ticket.providerID], current == ticket {
            // The SAME ticket identity carries into the pending record: the
            // eventual settlePending must present it (exact-identity
            // release; nothing else can free this owner). The witness is the
            // EXACT observer that minted the receipt — retained runtime-only
            // so registry removal/replacement cannot strand the pending
            // owner (MC-OBSERVER-PENDING-OWNER).
            slots[ticket.providerID] = .pending(
                ProviderPendingRecord(ticket: ticket,
                                      intent: intent,
                                      receipt: receipt,
                                      lease: lease,
                                      witness: witness),
                recoveryLeaseID: nil)
            return true
        }
        return false
    }

    public func pendingRecord(providerID: UUID) async -> ProviderPendingRecord? {
        if case let .pending(record, _)? = slots[providerID] {
            return record
        }
        return nil
    }

    /// Release a pending owner with its EXACT ticket identity only (the
    /// reconciler read the individual physical truth first).
    public func settlePending(providerID: UUID,
                              ticket: ProviderOperationTicket) async -> Bool {
        if case let .pending(record, _)? = slots[providerID], record.ticket == ticket {
            slots.removeValue(forKey: providerID)
            return true
        }
        return false
    }

    /// One recovery-attempt holder per pending provider.
    public func tryAcquireRecoveryLease(providerID: UUID) async -> ProviderRecoveryLease? {
        guard case let .pending(record, existing)? = slots[providerID], existing == nil else {
            return nil
        }
        let lease = ProviderRecoveryLease(providerID: providerID, leaseID: UUID())
        slots[providerID] = .pending(record, recoveryLeaseID: lease.leaseID)
        return lease
    }

    public func releaseRecovery(_ lease: ProviderRecoveryLease) async {
        guard case let .pending(record, current)? = slots[lease.providerID],
              current == lease.leaseID else {
            return
        }
        slots[lease.providerID] = .pending(record, recoveryLeaseID: nil)
    }

    /// Diagnostics only (bounded counts; never enumerates content). The
    /// "preserve gate/runtime owned count until settled" test surface.
    public func activeOperationCount() async -> Int { slots.count }
    public func pendingOperationCount() async -> Int {
        var count = 0
        for slot in slots.values {
            if case .pending = slot { count += 1 }
        }
        return count
    }

    /// Providers with a pending owner (bounded iteration; content-free).
    public func pendingProviderIDs() async -> [UUID] {
        var ids: [UUID] = []
        for (providerID, slot) in slots {
            if case .pending = slot {
                ids.append(providerID)
                if ids.count >= Self.maximumPending { break }
            }
        }
        return ids
    }
}

// MARK: - Shared-context registry
//
// Keying rule (documented, instance-exact): one coordinator per LIVE
// DatabaseManager instance. Identity uses the actor instance itself (===);
// ObjectIdentifier is only the dictionary index and is re-validated, so a
// deallocated instance's recycled address can never attach a stale
// coordinator to a new context. Entries are pruned when their database is
// gone (weak), which is exactly the process-lifetime semantics the pending
// records have anyway (a dead context's RAM pending state is meaningless;
// the durable ledger + restart drain is the recovery path).

public final class ProviderOperationCoordinatorRegistry: @unchecked Sendable {
    public static let shared = ProviderOperationCoordinatorRegistry()

    private final class Entry {
        weak var database: DatabaseManager?
        let coordinator: ProviderOperationCoordinator
        init(database: DatabaseManager, coordinator: ProviderOperationCoordinator) {
            self.database = database
            self.coordinator = coordinator
        }
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    public func coordinator(for database: DatabaseManager) -> ProviderOperationCoordinator {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(database)
        if let entry = entries[key], entry.database === database {
            return entry.coordinator
        }
        if entries[key] != nil {
            // Recycled address of a dead context: drop it and any other dead
            // entries opportunistically.
            entries[key] = nil
            for (staleKey, stale) in entries where stale.database == nil {
                entries.removeValue(forKey: staleKey)
            }
        }
        let coordinator = ProviderOperationCoordinator()
        entries[key] = Entry(database: database, coordinator: coordinator)
        return coordinator
    }

    /// Test isolation helper: forgets resolved instances (never clears
    /// another live context's state — the coordinator actor owns it).
    internal func removeAllForTesting() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}