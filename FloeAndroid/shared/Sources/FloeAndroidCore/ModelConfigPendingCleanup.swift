// SPDX-License-Identifier: MPL-2.0
//
// RB2 — ProviderSecretCleanup: the INDEPENDENT COMPLETE recovery path for
// provider-scoped secret deletion/clearing, REPAIRED per
// MAIN_SOURCE_REVIEW_20261019.json MC-R2/R3/R4 (private source candidate;
// NOT compiled, NOT executed).
//
// Repair delta over the parent (job-d02beb16bd1840a9):
// * MC-R2 — the ledger decoder is now STRICT and BOUNDED and distinguishes
//   ABSENT (row missing) from CORRUPT (present-but-invalid). Corrupt,
//   non-array, wrong-typed, invalid-late-row, duplicate, over-cap and
//   raw-bytes-exceed-bound ledgers are typed `persistenceUnavailable`
//   failures that preserve the EXACT stored bytes across every attempted
//   enqueue/dequeue/drain — the next write can no longer silently overwrite
//   the original recovery intents with an empty/filtered list (the parent's
//   decode-to-[] + skip-invalid + truncate->256 + rewrite chain destroyed
//   them). Raw bytes are bound BEFORE deserialization (schema-derived
//   object bound, not "deserialize an arbitrarily huge blob first"). Valid
//   later entries are never dropped: strict = all-or-nothing on the BYTES,
//   and once the corruption is resolved every retained entry drains.
// * MC-R3 — effectAbsent from pre-ticket validation
//   (invalidReference/invalidValue) means "this attempt created no ticket",
//   NOT "the secret is absent". Finalization of a deletion intent happens
//   ONLY on the operation's actual committed completion or the
//   authoritative settled read-miss (status 2). Validation rejections keep
//   the durable entry and report a retryable/diagnostic typed outcome.
//   No assertion was weakened: `secretAlreadyAbsent` remains only as the
//   honest authoritative-absence channel (documented unreachable via
//   pre-ticket errors).
// * MC-R4 — the drain holds the operation identity across the TRUE effect
//   lifetime: an attempt whose INDIVIDUAL physical signal shows execution
//   still outstanding (or unobserved with an ambiguous outcome) PARKS its
//   ticket + retained registry lease into the shared coordinator instead of
//   releasing gate+lease like the parent did; the entry stays; a later drain
//   reconciles via the physical truth or process restart. New-resource Set
//   also records a durable `.secretWrite` intent BEFORE the first native
//   effect (see the ingress executor), and this ledger's row-resolving
//   branches never delete a secret a LIVE row owns.
// * The ProviderOperationOwning seam is upgraded to EXACT-TICKET identity
//   (release cannot free a later owner; pending owners block new operations
//   and expose a bounded recovery-lease reconciliation seam).
//
// Why an independent path (unchanged, exact source/effect identification):
// the ORIGINAL cleanup machinery is the credential_records tool vault — the
// `credential_deletion_queue` table is filled by the schema TRIGGER
// `credential_delete_queue` fired by BEFORE DELETE ON credential_records
// (FloePersistence Migrations/V11ArchiveCredentials.swift :48-61), and
// drained through CredentialStore.pendingDeletions/completeDeletion/
// recordDeletionFailure (CredentialStore.swift:176-193) by
// CredentialVaultService.drainDeletionQueue (FloeSync CredentialVaultService.
// swift :49-53 ordering; AppEnvironment.swift:1716 bootstrap drain call).
// That queue can ONLY record rows whose metadata came from credential_
// records — a provider delete has no credential_records row, so the original
// queue CANNOT express provider-scoped recovery. Reusing or extending it
// would modify the tool-vault lane's code/schema. Therefore RB2 implements
// the SAME honest ordering semantics (enqueue -> backend delete -> complete
// | record failure; bootstrap drain replays) with its OWN ledger inside the
// existing schema-46 app_settings table (fixed whitelist key; no schema
// change; no second business DB; no secret/plaintext bytes in the ledger).
//
// Coordination facts for the vault lane (job-07f0d672e3854e17): account
// prefixes are disjoint BY CONSTRUCTION (provider.<uuid> vs
// credential.<uuid>|host.ssh.*|host.vnc.*|approval-model); the vault queue
// enumerates its own table, never account strings; the trigger cannot fire
// for provider deletes. The coordinator here is COMPATIBLE with that lane's
// delivered CredentialVaultOperationCoordinator shape and the public typed
// outcomes are the reconciliation seam if Main later subsumes provider
// journaling.
//
// CV-R1/R2/R3 discipline (carried from the parent, still enforced): drain
// and saves are mutually gated BOTH directions on the SAME shared
// coordinator; the ledger carries NO timestamp in any decision path (CV-R2:
// identity is (providerID, intent), finalization is compare-and-delete);
// the drain iterates the snapshot with no OFFSET paging (CV-R3).
//
// Recovery semantics (Main effect-disposition rule + CV-R1..R4 + MC-R4):
// * Entry means "an intent to remove the secret at reference(provider.<uuid>)
//   was established (delete/clear) OR a new-resource secret write was
//   intended/possibly committed before its metadata (.secretWrite)".
// * Drain resolves each entry against the ACTUAL current provider row:
//     - intent providerDelete + row still exists  => the DB delete aborted
//       before commit; the live provider still OWNS the secret; the entry is
//       discarded WITHOUT deleting anything (never destroy a live provider's
//       key on boot).
//     - intent providerDelete + row absent        => retry the bounded
//       gateway delete; remove the entry only on the operation's committed
//       completion; outcomeUnknown keeps the entry AND parks the physical
//       owner until the individual signal settles (MC-R4).
//     - intent secretClear + row exists with a matching secretRef => a later
//       Set re-populated the SAME deterministic reference; the clear is
//       obsolete; discard WITHOUT deleting.
//     - intent secretClear + row exists with nil secretRef => the clear
//       committed in SQLite; retry the gateway delete as above.
//     - intent secretClear + row absent => degrade to providerDelete
//       semantics (delete the orphan if any).
//     - intent secretWrite + row exists with matching reference => the write
//       CONVERGED into a live row (this or a later save): the reference is
//       owned; discard WITHOUT deleting (never wipe a live/newer credential).
//     - intent secretWrite + row exists WITHOUT a matching reference => the
//       metadata landed without that secret (a later clear/delete path
//       owns resolution): attempt the bounded delete as providerDelete does.
//     - intent secretWrite + row absent => the create never committed; a
//       possibly-orphan key must not survive silently: attempt the bounded
//       orphan delete; remove the entry only on committed completion.
// * All ledger writes mirror the ORIGINAL SettingsStore upsert statement
//   (SettingsStore.swift:64-73) for the ONE fixed key.

import Foundation
import GRDB
import FloeCore
import FloePersistence

// MARK: - Owned-operation coordination seam (MC-R1/R2/R4 upgrades)

public enum ProviderOperationKind: String, Sendable, Equatable {
    case save      // Set / Keep / Clear draft→runner chain
    case delete    // provider delete (row + secret cleanup)
    case cleanup   // one ledger entry attempt during a drain
}

/// Typed integration seam consumed by the drain and by every provider write.
/// `beginOperation` is an ATOMIC reserve returning an EXACT ticket (MC-R4):
/// release happens only by presenting that ticket (`endOperation`), a
/// same-kind tokenless release cannot free a later owner. No timer releases
/// a reservation; an unsettled physical lifetime converts the reservation
/// into a durable pending owner (`parkPending`) that blocks new operations
/// until the INDIVIDUAL mailbox truth (never a re-read/counter/timeout)
/// settles it (`settlePending` via a bounded recovery lease).
/// MC-CAPACITY-1: the bounded reservation is taken at `beginOperation`
/// (running + pending share one per-operation budget); exhaustion is the
/// truthful `.capacityUnavailable` refusal BEFORE any side effect, and an
/// exact-ticket `parkPending` always succeeds (no post-effect strand).
public protocol ProviderOperationOwning: Sendable {
    func beginOperation(providerID: UUID,
                        kind: ProviderOperationKind) async -> ProviderOperationBeginOutcome
    func endOperation(_ ticket: ProviderOperationTicket) async
    @discardableResult
    func parkPending(_ ticket: ProviderOperationTicket,
                     intent: ProviderPendingIntent,
                     receipt: PhysicalOperationReceipt?,
                     lease: ConfigOwnedWorkLease?,
                     witness: (any PhysicalObservingSecretGateway)?) async -> Bool
    func pendingRecord(providerID: UUID) async -> ProviderPendingRecord?
    func settlePending(providerID: UUID, ticket: ProviderOperationTicket) async -> Bool
    func tryAcquireRecoveryLease(providerID: UUID) async -> ProviderRecoveryLease?
    func releaseRecovery(_ lease: ProviderRecoveryLease) async
    func activeOperationCount() async -> Int
}

/// Concrete per-instance gate kept for tests and explicit injection
/// (identical semantics to the shared coordinator, just not context-shared).
/// Production defaults to `ProviderOperationCoordinator` resolved by the
/// ACTUAL shared DatabaseManager instance (ProviderOperationCoordinator
/// .swift) — Main's MC-R4 rule forbids a default per-instance replacement
/// at runtime; this actor is never that default.
public actor ProviderOperationOwnership: ProviderOperationOwning {
    private enum Slot {
        case running(ProviderOperationTicket)
        case pending(ProviderPendingRecord, recoveryLeaseID: UUID?)
    }
    private var slots: [UUID: Slot] = [:]

    public init() {}

    /// MC-CAPACITY-1 parity with the shared coordinator: the bounded
    /// per-operation reservation is taken HERE, before any effect; the
    /// drain/save callers see a truthful pre-effect `.capacityUnavailable`
    /// instead of a post-effect park refusal that would strand the running
    /// slot and its receipt/lease.
    public func beginOperation(providerID: UUID,
                               kind: ProviderOperationKind) async
        -> ProviderOperationBeginOutcome
    {
        switch slots[providerID] {
        case .running: return .conflict
        case .pending: return .pendingReconciliation
        case nil:
            guard slots.count < ProviderOperationCoordinator.maximumPending else {
                return .capacityUnavailable
            }
            let ticket = ProviderOperationTicket(providerID: providerID,
                                                 kind: kind,
                                                 claimID: UUID())
            slots[providerID] = .running(ticket)
            return .attached(ticket)
        }
    }

    public func endOperation(_ ticket: ProviderOperationTicket) async {
        if case let .running(current)? = slots[ticket.providerID], current == ticket {
            slots.removeValue(forKey: ticket.providerID)
        }
    }

    @discardableResult
    public func parkPending(_ ticket: ProviderOperationTicket,
                            intent: ProviderPendingIntent,
                            receipt: PhysicalOperationReceipt?,
                            lease: ConfigOwnedWorkLease?,
                            witness: (any PhysicalObservingSecretGateway)? = nil) async -> Bool
    {
        if case let .running(current)? = slots[ticket.providerID], current == ticket {
            slots[ticket.providerID] = .pending(
                ProviderPendingRecord(ticket: ticket, intent: intent,
                                      receipt: receipt, lease: lease,
                                      witness: witness),
                recoveryLeaseID: nil)
            return true
        }
        return false
    }

    public func pendingRecord(providerID: UUID) async -> ProviderPendingRecord? {
        if case let .pending(record, _)? = slots[providerID] { return record }
        return nil
    }

    public func settlePending(providerID: UUID, ticket: ProviderOperationTicket) async -> Bool {
        if case let .pending(record, _)? = slots[providerID], record.ticket == ticket {
            slots.removeValue(forKey: providerID)
            return true
        }
        return false
    }

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
              current == lease.leaseID else { return }
        slots[lease.providerID] = .pending(record, recoveryLeaseID: nil)
    }

    /// Diagnostics only (bounded count; never enumerated content).
    public func activeOperationCount() async -> Int { slots.count }
}

// MARK: - Ledger model

/// One bounded cleanup intent. Secret-free by construction: provider UUID,
/// the deterministic account string, and intent class. Identity is exactly
/// (providerID, intent) — no timestamps in any decision path (CV-R2).
/// MC-R4: `secretWrite` is the NEW-RESOURCE durable write intent recorded
/// BEFORE the first native effect; its drain branch never deletes anything
/// a live row owns.
public struct ProviderSecretCleanupEntry: Sendable, Equatable, Codable {
    public enum Intent: String, Sendable, Equatable, Codable {
        case providerDelete
        case secretClear
        case secretWrite
    }
    public let providerID: UUID
    public let account: String
    public let intent: Intent

    public init(providerID: UUID, account: String, intent: Intent) {
        self.providerID = providerID
        self.account = account
        self.intent = intent
    }

    var dictionaryKey: String { providerID.uuidString }
}

// MARK: - Drain outcome

public struct ProviderSecretCleanupDrainResult: Sendable, Equatable {
    public enum EntryOutcome: Sendable, Equatable {
        case secretRemoved
        /// The ONLY authoritative-absence channel: reachable solely through
        /// an actual store completion that proves the exact reference is
        /// absent (settled read status 2 / backendSkippedNoEffect). MC-R3:
        /// pre-ticket invalidReference/invalidValue NEVER maps here.
        /// (Idempotent delete-success reports `secretRemoved`, matching the
        /// Keystore store's own semantics.)
        case secretAlreadyAbsent(reason: String)
        /// C1: may have executed; entry KEPT for retry — never reported as
        /// removed.
        case outcomeUnknownKeptForRetry(reason: String)
        /// MC-R4: the attempt's INDIVIDUAL physical execution is still
        /// outstanding (or unobserved with an ambiguous outcome); the entry
        /// is kept AND the cleanup owner (ticket + retained registry lease)
        /// is PARKED until the physical truth settles.
        case outcomeUnknownPendingOwnerKept(reason: String)
        /// Live row still owns the secret (delete/write converged, clear
        /// obsolete) or the delete aborted before commit. Nothing deleted;
        /// entry discarded only after compare-and-delete confirms the
        /// attempted intent is STILL the current entry (CV-R2).
        case intentResolvedWithoutDelete(reason: String)
        case gatewayUnregisteredKept
        /// MC-R3: an effect-absent disposition (pre-ticket validation or
        /// authoritative non-commit) proves THIS attempt mutated nothing —
        /// it is kept as an honest retry, NEVER reported as already-absent
        /// or removed.
        case effectRejectedKeptForRetry(reason: String)
        /// An active provider operation (save/delete/clear) holds the
        /// ownership reservation: the entry is KEPT untouched and a LATER
        /// drain retries (CV-R1 both-direction gate; no timer release).
        case activeOperationSkippedKept
        /// A durable PENDING owner holds the provider (MC-R4): entry kept;
        /// the drain attempted one bounded reconciliation first (recovery
        /// lease); the owner remains until the individual physical truth
        /// settles or the process restarts.
        case pendingOwnerSkippedKept(reason: String)
        /// The ACTUAL runtime owned-work registry refused attach (no
        /// admitted epoch / draining / retiring / store not ready): the
        /// entry is KEPT and no effect is attempted — quiescence honesty,
        /// never a fake zero (coordinator guidance 2026-10-19).
        case ownedWorkAttachKept(reason: String)
    }
    public var outcomes: [UUID: EntryOutcome]
    public var entriesRemaining: Int
}

// MARK: - Reconciler seam (drain consumes pending owners before attempting)

/// The drain asks this typed seam to run ONE bounded reconciliation for a
/// provider whose shared coordinator holds a pending owner. The concrete
/// implementation is ProviderSaveExecutor.reconcileProviderRecovery (MC-R4):
/// it reads ONLY the individual physical signal — never a fake settlement.
public protocol ProviderPendingReconciling: Sendable {
    func reconcileProviderRecovery(providerID: UUID) async -> ProviderRecoveryOutcome
}

public enum ProviderRecoveryOutcome: Sendable, Equatable {
    case nothingPending
    /// The individual physical truth proved never-executed or completed;
    /// the owner + retained registry lease were released exactly once.
    case settledNow(reason: String)
    /// Still outstanding / unobserved / another recovery already running /
    /// the pending identity advanced.
    case stillPending(reason: String)
    /// Not admissible right now (gateway state prevents honest consumption;
    /// the owner remains pending).
    case notAdmitted(reason: String)
}

// MARK: - Cleanup queue

public actor ProviderSecretCleanup {
    static let key = ConfigSettingsKeys.providerSecretCleanup

    private let database: DatabaseManager
    private let store: ModelConfigurationStore

    init(database: DatabaseManager) {
        self.database = database
        self.store = ModelConfigurationStore(database: database)
    }

    // MARK: Ledger access (ONE fixed key; STRICT bounded codec)

    /// Strict read: ABSENT ⇒ []; VALID ⇒ the complete list; CORRUPT ⇒ typed
    /// failure with the stored bytes preserved (MC-R2). NEVER maps corrupt
    /// to empty.
    public func entries() async throws -> [ProviderSecretCleanupEntry] {
        let key = Self.key
        let raw: String?? = try await database.reader { db in
            try Self.readRaw(db, key: key)
        }
        switch Self.decode(raw) {
        case .absent:
            return []
        case .valid(let list):
            return list
        case .corrupt(let reason):
            throw ConfigDomainError(code: .persistenceUnavailable,
                                    reason: "cleanupLedgerCorrupt.\(reason)")
        }
    }

    /// Enqueue BEFORE any destructive effect (the contract ordering:
    /// "pendingDeletion enqueue -> gateway.delete(reference) -> complete |
    /// recordDeletionFailure"; MC-R4 adds the pre-native-write variant for
    /// new resources). Idempotent per (providerID, intent). A corrupt or
    /// saturated ledger fails CLOSED before the caller performs any effect
    /// AND without rewriting the stored bytes (MC-R2).
    public func enqueue(_ entry: ProviderSecretCleanupEntry) async throws {
        let key = Self.key
        let maximum = Self.maximumEntries
        try await database.writer { db in
            let raw = try Self.readRaw(db, key: key)
            switch Self.decode(raw) {
            case .corrupt(let reason):
                // Preserve exact bytes: NOTHING is written on this path.
                throw ConfigDomainError(code: .persistenceUnavailable,
                                        reason: "cleanupLedgerCorrupt.\(reason)")
            case .absent:
                try Self.write(db, key: key, entries: [entry])
            case .valid(var list):
                if list.contains(where: {
                    $0.dictionaryKey == entry.dictionaryKey && $0.intent == entry.intent
                }) {
                    return
                }
                // One intent per provider at a time (identity advanced
                // intentionally: replace, never duplicate — the decoder
                // treats duplicates as corruption).
                list.removeAll { $0.dictionaryKey == entry.dictionaryKey }
                guard list.count < maximum else {
                    throw ConfigDomainError(code: .persistenceUnavailable,
                                            reason: "cleanupLedgerSaturated")
                }
                list.append(entry)
                try Self.write(db, key: key, entries: list)
            }
        }
    }

    /// COMPARE-AND-DELETE finalization (CV-R2): an entry is removed only
    /// while it still carries the EXACT attempted intent, and only after a
    /// STRICT read (a corrupt ledger refuses to rewrite — MC-R2). A stale
    /// completion can never erase a newer intent; the return value tells the
    /// caller whether the matched entry was actually finalized.
    @discardableResult
    func dequeueMatching(providerID: UUID,
                         intent: ProviderSecretCleanupEntry.Intent) async throws -> Bool
    {
        let key = Self.key
        return try await database.writer { db in
            let raw = try Self.readRaw(db, key: key)
            switch Self.decode(raw) {
            case .corrupt(let reason):
                throw ConfigDomainError(code: .persistenceUnavailable,
                                        reason: "cleanupLedgerCorrupt.\(reason)")
            case .absent:
                return false
            case .valid(let list):
                guard list.contains(where: {
                    $0.providerID == providerID && $0.intent == intent
                }) else {
                    return false
                }
                var remaining = list
                remaining.removeAll { $0.providerID == providerID && $0.intent == intent }
                try Self.write(db, key: key, entries: remaining)
                return true
            }
        }
    }

    /// The ledger cap is a safety bound; reaching it must fail CLOSED before
    /// the caller performs any effect (an unrecorded intent could never be
    /// recovered), never silently drop an entry. MC-R2: the cap is enforced
    /// on the OBJECT count AND on the RAW bytes BEFORE deserialization.
    static let maximumEntries = 256

    // MARK: Drain (bootstrap replay; RB1 calls this before domain commands)

    /// Replays the recovery path described in the header. Each entry is
    /// processed under an ATOMIC `.cleanup` ownership reservation: while one
    /// entry's awaited row-observation + backend-delete run, no provider
    /// save/delete/clear can interleave on that provider (and vice versa —
    /// CV-R1). Skipped and kept entries are counted truthfully; nothing is
    /// released by time and no OFFSET paging assumes stability (CV-R3). A
    /// provider with a durable PENDING owner gets ONE bounded reconciliation
    /// attempt via `reconciler` (MC-R4) before being skipped-and-kept.
    func drain(gateway: any SecretGatewayServicing,
               ownership: any ProviderOperationOwning,
               ownedWork: ConfigOwnedWorkLifecycle,
               reconciler: (any ProviderPendingReconciling)? = nil) async throws
        -> ProviderSecretCleanupDrainResult
    {
        var result = ProviderSecretCleanupDrainResult(outcomes: [:], entriesRemaining: 0)
        let current: [ProviderSecretCleanupEntry]
        do {
            current = try await entries()
        } catch let error as ConfigDomainError
        where error.reason.hasPrefix("cleanupLedgerCorrupt") {
            // MC-R2: corrupt bytes preserved; NO entry attempted. The typed
            // failure propagates to the bootstrap caller (ordinary commands
            // keep serving; recovery intents are never erased by a retry).
            throw error
        }
        for entry in current {
            // MC-R4 pending-owner first: reconcile via the individual
            // physical truth, or keep the entry honestly gated.
            if await ownership.pendingRecord(providerID: entry.providerID) != nil {
                guard let reconciler else {
                    result.outcomes[entry.providerID] =
                        .pendingOwnerSkippedKept(reason: "noReconcilerBound")
                    continue
                }
                switch await reconciler.reconcileProviderRecovery(providerID: entry.providerID) {
                case .nothingPending:
                    break // slot freed between check and reconcile; proceed
                case .settledNow:
                    break // owner released; proceed to the normal attempt
                case .stillPending(let reason):
                    result.outcomes[entry.providerID] =
                        .pendingOwnerSkippedKept(reason: reason)
                    continue
                case .notAdmitted(let reason):
                    result.outcomes[entry.providerID] =
                        .pendingOwnerSkippedKept(reason: "notAdmitted.\(reason)")
                    continue
                }
            }
            let ticket: ProviderOperationTicket
            switch await ownership.beginOperation(providerID: entry.providerID,
                                                  kind: .cleanup) {
            case .conflict:
                result.outcomes[entry.providerID] = .activeOperationSkippedKept
                continue
            case .pendingReconciliation:
                result.outcomes[entry.providerID] =
                    .pendingOwnerSkippedKept(reason: "pendingAppeared")
                continue
            case .capacityUnavailable:
                // MC-CAPACITY-1: the reservation refused BEFORE any effect;
                // nothing about this entry changed. Kept honestly (the
                // bounded state frees when other owners settle).
                result.outcomes[entry.providerID] =
                    .pendingOwnerSkippedKept(reason: "operationCapacityUnavailable")
                continue
            case .attached(let attachedTicket):
                ticket = attachedTicket
            }
            // ACTUAL runtime owned-work attach (the reviewed RB1 registry
            // port; kind .vaultMaintenance) held across the entry's awaited
            // row-observation + backend delete + finalization.
            let lease: ConfigOwnedWorkLease
            switch ownedWork.begin(kind: .vaultMaintenance,
                                   ownerID: entry.providerID.uuidString) {
            case .failure(let rejection):
                result.outcomes[entry.providerID] = ownedWorkAttachKeptOutcome(rejection)
                await ownership.endOperation(ticket)
                continue
            case .success(let attachedLease):
                lease = attachedLease
            }
            result.outcomes[entry.providerID] = await attempt(
                entry, gateway: gateway, ticket: ticket, lease: lease,
                ownership: ownership, ownedWork: ownedWork)
        }
        result.entriesRemaining = (try? await entries().count) ?? current.count
        return result
    }

    private func ownedWorkAttachKeptOutcome(
        _ rejection: ConfigOwnedWorkLifecycle.BeginRejection)
        -> ProviderSecretCleanupDrainResult.EntryOutcome
    {
        switch rejection {
        case .noAdmittedEpoch:
            return .ownedWorkAttachKept(reason: "noAdmittedRuntimeEpoch")
        case .invalidOwnerIdentity:
            return .ownedWorkAttachKept(reason: "ownedWorkInvalidOwner")
        case .rejected(let code):
            return .ownedWorkAttachKept(reason: "ownedWorkRejected.\(code)")
        }
    }

    /// One guarded entry attempt: decision against the ACTUAL row, then the
    /// bounded backend delete, then COMPARE-AND-DELETE finalization (CV-R2),
    /// with the MC-R3/MC-R4 rules:
    /// * pre-ticket validation rejections NEVER finalize (kept, diagnostic);
    /// * only the delete's OWN committed completion finalizes;
    /// * an unsettled individual physical lifetime PARKS this cleanup's
    ///   ticket + registry lease instead of releasing them.
    /// Called only while this lane holds the `.cleanup` reservation for the
    /// entry's provider, so no provider operation can interleave on the same
    /// id between observation and effect (CV-R1 both-direction gate).
    private func attempt(_ entry: ProviderSecretCleanupEntry,
                         gateway: any SecretGatewayServicing,
                         ticket: ProviderOperationTicket,
                         lease: ConfigOwnedWorkLease,
                         ownership: any ProviderOperationOwning,
                         ownedWork: ConfigOwnedWorkLifecycle) async
        -> ProviderSecretCleanupDrainResult.EntryOutcome
    {
        let provider: ProviderProfile?
        do {
            provider = try await store.provider(id: entry.providerID)
        } catch {
            // Persistence itself failed: keep the entry; release our own
            // reservation truthfully (no backend effect attempted).
            ownedWork.settle(lease)
            await ownership.endOperation(ticket)
            return .outcomeUnknownKeptForRetry(reason: "rowQueryFailed")
        }
        enum Decision {
            case discardWithoutDelete(reason: String)
            case backendDelete
        }
        let decision: Decision
        switch (entry.intent, provider) {
        case (.providerDelete, .some):
            // The DB delete aborted before commit; the live provider still
            // OWNS the secret. Discard, delete nothing.
            decision = .discardWithoutDelete(reason: "deleteAbortedRowStillOwnsSecret")
        case (.secretWrite, .some(let row)):
            if row.secretRef?.keychainAccount == entry.account {
                // The write CONVERGED into the live row: owned by a live
                // provider (this or a later save). Never delete (MC-R4:
                // "newer live Set not deleted").
                decision = .discardWithoutDelete(reason: "writeConvergedRowOwnsSecret")
            } else {
                // Row exists without the intended reference: a possible
                // orphan at the deterministic reference must be settled.
                decision = .backendDelete
            }
        case (.secretClear, .some(let row)):
            if let persisted = row.secretRef,
               persisted.keychainAccount == entry.account {
                // A later Set re-populated the SAME deterministic reference;
                // the clear is obsolete. Do NOT delete.
                decision = .discardWithoutDelete(reason: "clearSupersededByNewerSet")
            } else {
                decision = .backendDelete
            }
        case (.providerDelete, nil), (.secretClear, nil), (.secretWrite, nil):
            decision = .backendDelete
        }
        if case .discardWithoutDelete(let reason) = decision {
            // Compare-and-delete finalization: only the exact attempted
            // intent is finalized — the reservation makes the invariant
            // enforced, not assumed. A corrupt-ledger throw here keeps the
            // entry (MC-R2) — never a silent loss.
            let finalized: Bool
            do {
                finalized = try await dequeueMatching(providerID: entry.providerID,
                                                      intent: entry.intent)
            } catch {
                ownedWork.settle(lease)
                await ownership.endOperation(ticket)
                return .outcomeUnknownKeptForRetry(reason: "entryIntentAdvanced")
            }
            ownedWork.settle(lease)
            await ownership.endOperation(ticket)
            return finalized
                ? .intentResolvedWithoutDelete(reason: reason)
                : .outcomeUnknownKeptForRetry(reason: "entryIntentAdvanced")
        }
        guard gateway.isRegistered else {
            ownedWork.settle(lease)
            await ownership.endOperation(ticket)
            return .gatewayUnregisteredKept
        }
        let reference = ConfigSecretIdentity.providerOpaqueReference(
            for: ConfigSecretIdentity.providerSecretReference(account: entry.account,
                                                              synchronizable: false))
        // MC-R4: when the gateway exposes the individual physical seam the
        // drain's delete uses it and classifies from the per-operation truth,
        // never from the returned error value alone.
        let observed = PhysicalObservationResolver.observer(for: gateway)
        let capture = ReceiptCapture()
        let assessment: SecretEffectAssessment
        do {
            if let observed {
                try await observed.deleteObserved(reference: reference) { receipt in
                    capture.set(receipt)
                }
                // Success IS the authoritative completion channel: the
                // caller continuation only resumes from the mailbox
                // complete() (GWS-7 pairing ⇒ delete success = status 4).
                var settlement: PhysicalSettlement = .executionSettled(status: 4)
                if let receipt = capture.receipt {
                    let snapshot = observed.physicalSnapshot(claim: receipt.claim)
                    if case .settled(let status) = snapshot {
                        settlement = .executionSettled(status: status)
                    }
                    _ = observed.resolvePhysical(claim: receipt.claim)
                } else {
                    settlement = .unobserved
                }
                assessment = SecretEffectAssessment(disposition: .committed,
                                                    settlement: settlement,
                                                    receipt: capture.receipt)
            } else {
                try await gateway.delete(reference: reference)
                // Success via the frozen CRUD contract is itself the terminal
                // completion event (delete ⇒ status 4 committed).
                assessment = SecretEffectAssessment(disposition: .committed,
                                                    settlement: .executionSettled(status: 4),
                                                    receipt: nil)
            }
        } catch {
            let snapshot: PhysicalOperationSnapshot
            if let observed, let receipt = capture.receipt {
                snapshot = observed.physicalSnapshot(claim: receipt.claim)
            } else {
                snapshot = .notRecorded
            }
            assessment = SecretPhysicalAssessor.assess(error: error,
                                                       receipt: capture.receipt,
                                                       snapshot: snapshot,
                                                       supportsObservation: observed != nil)
        }
        switch assessment.disposition {
        case .committed:
            let finalized = (try? await dequeueMatching(providerID: entry.providerID,
                                                        intent: entry.intent)) ?? false
            ownedWork.settle(lease)
            await ownership.endOperation(ticket)
            return finalized
                ? .secretRemoved
                : .outcomeUnknownKeptForRetry(reason: "entryIntentAdvanced")
        case .effectAbsent(let reason):
            // MC-R3: "no effect from THIS attempt" never proves the
            // pre-existing secret absent, and an authoritative non-commit
            // (rejected store write) means the secret MAY still exist while
            // the row no longer references it: the entry is KEPT for honest
            // retry. Nothing here finalizes/dequeues.
            ownedWork.settle(lease)
            await ownership.endOperation(ticket)
            return .effectRejectedKeptForRetry(reason: reason)
        case .outcomeUnknown(let reason):
            // NEVER report removal from an unknown outcome. MC-R4: if the
            // individual physical lifetime is still outstanding (or
            // unobserved), PARK this cleanup owner — entry stays AND the
            // registry lease stays attached until the real signal settles.
            if assessment.requiresOwnerRetention {
                // MC-CAPACITY-1: the reservation was taken at begin, so the
                // exact-ticket park always retains ticket + lease + receipt.
                let parked = await ownership.parkPending(
                    ticket,
                    intent: pendingIntent(for: entry.intent),
                    receipt: assessment.receipt,
                    lease: lease,
                    witness: observed)
                return parked
                    ? .outcomeUnknownPendingOwnerKept(reason: reason)
                    : .outcomeUnknownKeptForRetry(reason: "\(reason).parkRefused")
            }
            ownedWork.settle(lease)
            await ownership.endOperation(ticket)
            return .outcomeUnknownKeptForRetry(reason: reason)
        }
    }

    private func pendingIntent(for intent: ProviderSecretCleanupEntry.Intent)
        -> ProviderPendingIntent
    {
        switch intent {
        case .providerDelete: return .providerDelete
        case .secretClear: return .secretClear
        case .secretWrite: return .secretWrite
        }
    }

    // MARK: Codec (ONE fixed key; mirrors SettingsStore.swift:52-60/:64-73)

    enum LedgerDecode: Equatable {
        case absent
        case valid([ProviderSecretCleanupEntry])
        case corrupt(reason: String)
    }

    /// Bound derived from the ACTUAL schema shape, applied to the RAW BYTES
    /// BEFORE any deserialization (MC-R2: never deserialize an arbitrarily
    /// huge unbounded blob first).
    ///
    /// One entry (sorted-key JSON, no whitespace, ASCII fixed fields):
    ///   {"account":"provider.<36>"   → 11+1+9+45+1  ≈ 67 B (account max)
    ///    "intent":"providerDelete"   →  8+1+14+1    = 24 B (intent max)
    ///    "providerID":"<36>"         } → 12+1+36+1  = 50 B
    /// plus braces/quotes/commas overhead ⇒ per-entry maximum ≈ 144 B.
    /// 256 entries ⇒ 36,864 B + 2 array bytes; the closed constant below is
    /// exactly `maximumEntries * 144 + 64` — a generous schema maximum with
    /// the derivation, NOT a parse-then-check.
    static let maximumLedgerJSONBytes = maximumEntries * 144 + 64

    /// (row-present?, value_json?) — the OUTER nil is the ONLY honest
    /// ABSENT signal (no app_settings row for our fixed key). A present row
    /// with NULL/garbage is foreign/corrupt state that must be preserved,
    /// never treated as "empty" (MC-R2 absent-distinct-from-corrupt).
    private static func readRaw(_ db: Database, key: String) throws -> String?? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT value_json FROM app_settings WHERE key = ?",
            arguments: [key]
        ) else {
            return nil
        }
        let text: String? = row["value_json"]
        return .some(text)
    }

    /// STRICT, bounded, all-or-fail decode (see header + tests). Reasons are
    /// closed machine identifiers; the corrupt content is NEVER echoed.
    static func decode(_ raw: String??) -> LedgerDecode {
        guard case .some(let text) = raw else { return .absent }
        guard let text else { return .corrupt(reason: "nullValueJSON") }
        guard text.utf8.count <= maximumLedgerJSONBytes else {
            return .corrupt(reason: "rawBytesExceedBound")
        }
        guard let data = text.data(using: .utf8) else {
            return .corrupt(reason: "notUTF8")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data,
                                                      options: [.fragmentsAllowed])
        } catch {
            return .corrupt(reason: "malformedJSON")
        }
        guard let array = parsed as? [Any] else {
            return .corrupt(reason: "notArray")
        }
        guard array.count <= maximumEntries else {
            return .corrupt(reason: "entryCountExceedsBound")
        }
        var entries: [ProviderSecretCleanupEntry] = []
        var seenProviders = Set<UUID>()
        var seenIdentities = Set<String>()
        for element in array {
            guard let object = element as? [String: Any], object.count == 3 else {
                return .corrupt(reason: "entryNotClosedObject")
            }
            guard let idString = object["providerID"] as? String,
                  let providerID = UUID(uuidString: idString),
                  let account = object["account"] as? String,
                  account.utf8.count <= 128,
                  account == ConfigSecretIdentity.providerAccount(providerID: providerID),
                  let intentRaw = object["intent"] as? String,
                  let intent = ProviderSecretCleanupEntry.Intent(rawValue: intentRaw)
            else {
                return .corrupt(reason: "entryInvalidField")
            }
            let identity = "\(providerID.uuidString)|\(intent.rawValue)"
            guard seenIdentities.insert(identity).inserted else {
                return .corrupt(reason: "duplicateEntry")
            }
            guard seenProviders.insert(providerID).inserted else {
                return .corrupt(reason: "duplicateProviderID")
            }
            entries.append(ProviderSecretCleanupEntry(providerID: providerID,
                                                      account: account,
                                                      intent: intent))
        }
        return .valid(entries)
    }

    private static func write(_ db: Database, key: String,
                              entries: [ProviderSecretCleanupEntry]) throws {
        var array: [[String: Any]] = []
        array.reserveCapacity(entries.count)
        for entry in entries {
            array.append([
                "providerID": entry.providerID.uuidString,
                "account": entry.account,
                "intent": entry.intent.rawValue,
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: array, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        // MC-R2 self-check: refuse to write beyond the documented bound
        // (saturation is typed, never a silent truncation).
        guard array.count <= maximumEntries, json.utf8.count <= maximumLedgerJSONBytes else {
            throw ConfigDomainError(code: .persistenceUnavailable,
                                    reason: "cleanupLedgerSaturated")
        }
        try db.execute(
            sql: """
                INSERT INTO app_settings (key, value_json, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value_json = excluded.value_json,
                    updated_at = excluded.updated_at
                """,
            arguments: [key, json, Self.timestamp(Date())]
        )
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Small controlled helpers (RB2-owned)

/// Thread-safe one-shot receipt holder for the observed gateway callbacks
/// (the mailbox delivers OUTSIDE its lock; this box only stores the value).
final class ReceiptCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PhysicalOperationReceipt?
    func set(_ receipt: PhysicalOperationReceipt) {
        lock.lock()
        if value == nil { value = receipt } // exact one delivery per call
        lock.unlock()
    }
    var receipt: PhysicalOperationReceipt? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}