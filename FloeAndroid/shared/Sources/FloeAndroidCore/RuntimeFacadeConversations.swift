// SPDX-License-Identifier: MPL-2.0
//
// RB-3 ConversationDomain — ordinary conversation / history / content backend
// (private source candidate; NOT compiled, NOT executed, NOT registered).
//
// Authority chain (READ FIRST):
// * Local/Private/android-g02-20261018/RB3_CONVERSATION_HISTORY_SOURCE_ADMISSION_20261019.json
//   — Main opaque conversation-revision clarification: the canonical
//   `floe.conversation-row.v1` FULL RAW-ROW digest replaces the historical
//   updatedAt-only revision sketch for the stateful metadata commands.
//   "Wire baseRevision.version structurally opaque nonblank string";
//   "No new table/revision counter/schema or iOS source edit." Main
//   reconfirmed this in current coordinator guidance: the full raw-row
//   revision is SETTLED, not a draft updatedAt design.
// * runtime-facade-contract/contract.json commandVocabulary conversation.* +
//   service-map.json nodes convstore/intelstore/runstore/inputstore/
//   workspacestore/fence/contentreader/convcenter (rev3).
// * BRIDGE_V3_MAIN_DECISIONS.json (scopes, receipts, revisions).
// * FloeAndroid/shared/Sources/FloeAndroidCore/BridgeEnvelopeV3.swift
//   (live, sha256 8454099c85a757ec414dcaea103dd6c120cccb87f529e462e8c7cb0a6643adaa —
//   the frozen v3 envelope grammar: conversationLifecycle requires
//   owner.taskID and rejects run/env/job; launch conversation.create requires
//   explicit createIntent and forbids owner/revision; revision =
//   {resourceID, version}, both nonblank, never trimmed; handlerKey =
//   BridgeV3.handlerKey(scope:command:)).
// * settings-domain-p0-final-alignment MAIN_SOURCE_QUALIFICATION_ADMISSION
//   _20261019.json — the P0 helpers `SettingsDomainV1.CanonicalDigest` and
//   `SettingsDomainV1.ContentBudget` are consumed BY NAME from the final
//   accepted P0 source. The named P0 qualifier (a8) may repair the chunk
//   budget / usage error reason; the final binding MUST consume the actual
//   qualified P0 API (see dependencyHashEvolution in
//   settings-defaults-usage-source/MAIN_SOURCE_ACCEPTANCE_20261019.json).
//   This adapter never copies or restores an older helper body.
// * runtime-bootstrap-main-reviewed-source/ (Main-reviewed frozen RB1:
//   MAIN_SOURCE_INTEGRATION_ADMISSION_20261019.json, MANIFEST.json, archive
//   sha256 e975c8a0089a4807d1ed9bcbd22325a52013ba84cf69bbce5f5f1e6da6ae5529;
//   still NOT published, NOT compiled, ordinary domainReady false). This
//   lane binds to that ACTUAL API — never a guessed one:
//     - `FacadeContentReader` (reviewed candidate, sha256
//       466f2231a190a68cd3c671f528104e4e5e1fabf60a87e82960d72f4a3763e1c7):
//       `init(generation:)`, `stage(_ content: Data) -> StageOutcome`,
//       `read(handle:offset:maxBytes:) -> ReadOutcome`, `release(handle:)`,
//       `retireAll()`; owned per generation inside `AndroidRuntimeBootstrap
//       .Generation.content`. The content authority below delegates through
//       a narrow structural port (see RuntimeFacadeConversationContent.swift)
//       and adds ONLY the trusted owner-binding index — no parallel cache.
//     - `RuntimeOperationReceipt` (`op:v1:`+32hex, reviewed FacadeEffectPump
//       .swift:33) — queue receipts are minted by the mailbox and carry NO
//       domain identity; `RuntimeEffectItem.Kind.prepared/started` are
//       NON-terminal live stages (Main's reviewed overlay:isTerminal
//       exhaustive, FacadeEffectPump.swift:72-79) emitted ONLY after an
//       actual atomic commit mints real ids.
//     - `AndroidRuntimeBootstrap.MissingBinding.conversationDomain`
//       (reviewed RuntimeFacadeBootstrap.swift:89) is the typed admission
//       barrier for THIS very domain: Main removes that case only when the
//       real binder installs these handlers after compilation/qualification.
//       Source alone registers nothing and flips nothing.
//     - `RuntimeOwnedWorkRegistry` (reviewed RuntimeFacadeBootstrap.swift:
//       kind enum :1054, attach :1139, exact-token detach :1178,
//       isAttached :1187, countsByKind :1199, retirement waitForDrain
//       :1217) is the REAL owned-work accounting the deletion lifecycle
//       composes with — the conversation/ run/ childRun/ tool kinds are RB4
//       (job-f6772d4de1584403) attaches/detaches; vaultMaintenance is the
//       vault-07 lane (job-07f0d672e3854e17). CH-R2 correction: the
//       `countsByKind(for: epoch)` map is GLOBAL root/epoch accounting, not
//       per conversation. It may not gate deleting conversation A on
//       unrelated B. The target report therefore carries the RB4 owner's
//       exact token mapping + real `isAttached` values. See
//       ConversationDeletionLifecycle below.
//
// Main review corrections implemented here (2026-10-19):
// * CH-R1 — the expected raw-row/purpose CAS, original memory preservation
//   and the ORIGINAL ConversationStore delete (RunLifecycleRetention, FK
//   cascades, V11/V36 triggers) run in ONE `DatabaseManager.writer`
//   transaction through a narrow ADDITIVE overload in the private mirror of
//   `ConversationStore.swift`. The upstream/live file (a symlink into
//   FloeAgent) is byte-untouched; no store fork and no second delete path.
// * CH-R2 — per-conversation exact `RuntimeOwnedWorkToken` evidence with
//   real `isAttached` truth; global epoch counts remain root accounting only
//   and never block/cancel unrelated work.
// * CH-R3 — operation-owned `ConversationDeletionFence` (conversation +
//   epoch + operation + authority receipt) with explicit begin / drain /
//   commit / abort on every exit; foreign/old tokens are refused by the
//   authority and can never clear a newer guard.
//
// Original sources reused (never forked, never edited):
// * FloeAgent/Sources/FloePersistence/ConversationStore.swift
//   (sha256 e7f5f616034683672bd740e3a921496f04b5382dd720fdd2af7787fd04e1d876,
//   live overlay a symlink into the protected FloeAgent upstream):
//   conversations(includeArchived:) predicate/order (:227-236),
//   conversation(id:) (:238-247), renameConversation UPDATE (:249-256),
//   setArchived UPDATE (:378-389), messagePage keyset page (:481-534),
//   deleteConversation one-writer transaction (:280-287). The private
//   candidate mirror adds ONLY the marked expected-row overload at the end
//   of the actor; the default method and every existing caller are
//   byte-unchanged.
// * FloeAgent/Sources/FloePersistence/PersistenceCodec.swift (:9-25):
//   ISO-8601 fractional-seconds codec. It is INTERNAL to FloePersistence, so
//   the two PURE format lines are locally mirrored (exactly as the accepted
//   settings-defaults adapter does); NO shared source is edited.
// * FloeAgent/Sources/FloeAgentRuntime/IntelligenceStore.swift:
//   SQLiteIntelligenceStore.search (:1018-1078) is the CHA-SEARCH
//   authority — delegated, never reimplemented; no second FTS index, no new
//   schema, no local model/embedding inference;
//   preserveMemoriesBeforeConversationDeletion (:684-…).
// * FloeAgent/Sources/FloePersistence/RunStore.swift runs ordering (:319-326),
//   RunningInputStore pending predicate/order (:63-71),
//   WorkspaceStore taskPolicy (:459-468), workspaceID/workspace
//   (:281/:144), conversations(workspaceID:) (:268),
//   pendingLocalCleanup/finishLocalCleanup (:115-131), deleteWorkspace (:195-209),
//   assignConversation (:371-398) + linkConversation projection (:224-243).
// * FloeAgent/FloeApp/Remote/ConversationCenter.swift native behavior mirrors:
//   createConversation (:1609-1624), sessionSnapshot first screen (:1386-1408),
//   renameConversation (:5981-5990), deleteConversation (:5938-5979),
//   stopRunsAndDelete (:6106-6176), retryPendingLocalCleanup partner
//   WorkspaceCenter (:380-443), waitForLaunches (:7498-7516).
//   NOTE: the native waitForLaunches 15-second safety net is NOT mirrored:
//   before a destructive delete the facade must reach REAL quiescence (RB3
//   admission: "no timer-release of outstanding I/O").
// * FloeAgent/Sources/FloeCore/LaunchEpochFence.swift:5-38 — the fence is
//   RB4-owned runtime state reached THROUGH ConversationDeletionLifecycle;
//   this package never touches a fence instance directly.
//
// Narrow original-SQL mirrors exist ONLY where the public actor is unbounded
// (conversation list paging, run snapshot window, message existence probe) or
// lacks an atomic CAS (rename/archive) or needs a test-visible single commit
// transaction (create). Each mirror copies the exact original WHERE/ORDER/
// UPDATE text and is pinned by source-equivalence tests against the public
// store APIs. No mirror adds a table, index, column, revision counter or
// second database. Production DB is exactly the ORIGINAL schema 46.
//
// No handler is registered here and no capability is advertised: a real host
// binder (Main, after accepted gateway/P0/RB1 publication + the RB4 concrete
// lifecycle adapter) composes `ConversationDomainHandlerPlan` into the
// runtime registry and removes `MissingBinding.conversationDomain`.
// Temporary chats never reach these paths (EphemeralStores own them;
// purpose 'temporary' is not even persistable — V41 CHECK allows only
// 'ordinary'|'notes'), and the Notes workspace keeps independent storage:
// this domain refuses every purpose != 'ordinary' row as a typed notFound
// indistinguishable from an absent row.

import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime

// MARK: - Opaque conversation revision (floe.conversation-row.v1)

/// Canonical FULL RAW-ROW digest used as the Android opaque resource version
/// for the stateful conversation metadata commands. Computed inside the SAME
/// original reader/writer snapshot from the actual `conversations` row
/// columns with the accepted P0 `SettingsDomainV1.CanonicalDigest`
/// type-tagged, length-prefixed encoding (no CAST/COALESCE/date formatting/
/// delimiter join). Deterministic because the pairs are sorted by column
/// name and every value carries its storage-class tag + length prefix, so
/// two different rows can never alias regardless of title Unicode,
/// delimiters or embedded control characters.
public enum ConversationRowRevision {
    /// Admission-pinned domain literal. Defined HERE, not added to P0 (no
    /// upstream edit); CanonicalDigest is domain-parameterized by design.
    public static let domain = "floe.conversation-row.v1"
    public static let resourcePrefix = "conversation."

    public static func resourceID(conversationID: UUID) -> String {
        resourcePrefix + conversationID.uuidString
    }

    /// The revision must name the SAME conversation that owns the command.
    /// Compares PARSED UUIDs, not raw spelling — the frozen precedent is
    /// the v3 cursor rule "Compare parsed UUID values (not raw spelling)"
    /// (BridgeEnvelopeV3.swift:721-726).
    public static func matches(revisionResourceID: String, conversationID: UUID) -> Bool {
        guard revisionResourceID.hasPrefix(resourcePrefix) else { return false }
        let raw = String(revisionResourceID.dropFirst(resourcePrefix.count))
        guard let parsed = UUID(uuidString: raw) else { return false }
        return parsed == conversationID
    }

    /// Deterministic sorted column-name + type-tagged DatabaseValue pairs
    /// over the REAL conversation row: every column the row actually has
    /// (identity, ownership-relevant columns, all mutable metadata and any
    /// future column), name-sorted. Absent row → nil (typed notFound).
    public static func digest(of row: Row) -> String {
        let pairs = row
            .map { (name: $0.0, value: $0.1) }
            .sorted { $0.name < $1.name }
        var fields: [SettingsDomainV1.CanonicalDigest.Field] = []
        fields.reserveCapacity(pairs.count * 2)
        for pair in pairs {
            fields.append(.text(pair.name))
            fields.append(field(pair.value))
        }
        return SettingsDomainV1.CanonicalDigest.rowToken(domain: domain, fields: fields)
    }

    /// One-row raw read inside a live GRDB transaction.
    public static func digest(db: Database, conversationID: UUID) throws -> String? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM conversations WHERE id = ?",
            arguments: [conversationID.uuidString]
        ) else { return nil }
        return digest(of: row)
    }

    static func field(_ value: DatabaseValue) -> SettingsDomainV1.CanonicalDigest.Field {
        switch value.storage {
        case .null: return .null
        case .int64(let value): return .integer(value)
        case .double(let value): return .real(value)
        case .string(let value): return .text(value)
        case .blob(let value): return .blob(value)
        }
    }
}

// MARK: - CH-R1 same-writer expected-row deletion contract

/// Immutable admission snapshot consumed by the additive
/// `SQLiteConversationStore.deleteConversation(id:expectedRow:beforeDelete:)`
/// seam. `verify(_:)` runs INSIDE the ORIGINAL store's writer transaction,
/// immediately before the original memory preservation and the original
/// `RunLifecycleRetention`/DELETE work, so the CAS, the memory reclassification
/// and the destructive writes are ONE atomic writer transaction. Legitimate
/// final owned-run writes during the real drain may only ADVANCE
/// `updated_at`; every other raw column (purpose, title, title_origin,
/// archived_at, is_searchable, id, ...) must still equal the admission
/// snapshot. Any other drift throws `staleRevision` before any write.
public struct ConversationDeleteExpectation: Sendable {
    public let purpose: String
    public let immutableFields: [String: SettingsDomainV1.CanonicalDigest.Field]
    public let updatedAtRaw: String

    public init(purpose: String,
                immutableFields: [String: SettingsDomainV1.CanonicalDigest.Field],
                updatedAtRaw: String) {
        self.purpose = purpose
        self.immutableFields = immutableFields
        self.updatedAtRaw = updatedAtRaw
    }

    public func verify(_ row: Row?) throws {
        guard let row else { throw ConversationDomainError.notFound }
        let actualPurpose: String = row["purpose"]
        // The purpose check is part of the same-writer CAS: a Notes/temporary
        // or otherwise foreign row can never be destroyed through this path.
        guard actualPurpose == purpose,
              actualPurpose == ConversationPurpose.ordinary.rawValue else {
            throw ConversationDomainError.notFound
        }
        var seen: Set<String> = []
        for (name, value) in row {
            seen.insert(name)
            if name == "updated_at" { continue }
            guard immutableFields[name] == ConversationRowRevision.field(value) else {
                throw ConversationDomainError.staleRevision
            }
        }
        guard seen == Set(immutableFields.keys).union(["updated_at"]) else {
            // A column appeared/disappeared mid-flight (schema drift or an
            // unauthorized writer): refuse before any destructive write.
            throw ConversationDomainError.staleRevision
        }
        // Same fixed-width codec grammar on both sides, so lexicographic
        // order equals chronological order; owned final writes may only
        // ADVANCE updated_at.
        let currentUpdated: String = row["updated_at"]
        guard currentUpdated >= updatedAtRaw else {
            throw ConversationDomainError.staleRevision
        }
    }
}

/// Narrow reusable synchronous mirror of
/// `SQLiteIntelligenceStore.preserveMemoriesBeforeConversationDeletion`
/// (IntelligenceStore.swift:684-701). It executes the EXACT original SQL on
/// the SAME `Database` handle inside the conversation-delete writer, so the
/// memory reclassification, the owned-record removal, the FK cascades and
/// the V11/V36 triggers all commit or roll back together. No nested awaited
/// store actor is ever entered inside the writer, and a stale-row refusal
/// happens BEFORE this UPDATE: a refused delete can never reclassify Notes
/// or another owner's memories.
public enum ConversationDeletionMemoryPreservation {
    /// Default ISO-8601 spelling used by the original private
    /// `IntelligenceStore.date(_:)` (`ISO8601DateFormatter` without
    /// fractional seconds). The SQL text and the 90-day retention are the
    /// original values.
    static func date(_ value: Date) -> String {
        ISO8601DateFormatter().string(from: value)
    }

    public static func preserve(db: Database, conversationID: UUID,
                                ownerLabel: String) throws {
        let now = date(Date())
        let retainedUntil = date(Date().addingTimeInterval(90 * 86_400))
        try db.execute(sql: """
            UPDATE memory_entries SET
                origin_conversation_id = COALESCE(origin_conversation_id, conversation_id),
                origin_owner_label = COALESCE(origin_owner_label, ?),
                owner_deleted_at = COALESCE(owner_deleted_at, ?),
                conversation_id = NULL,
                retained_until = COALESCE(retained_until, ?)
            WHERE conversation_id = ?
            """, arguments: [String(ownerLabel.prefix(120)), now,
                retainedUntil, conversationID.uuidString])
    }
}

// MARK: - Typed wire failures

/// Frozen contract errorCodeVocabulary subset for this domain
/// (contract.json commandVocabulary.errorCodeVocabulary). `wireReason` never
/// carries row content, paths or secrets.
public enum ConversationDomainError: Error, Sendable, Equatable {
    case invalidEnvelope(String)
    case notFound
    case staleRevision
    case sessionFenced(String)
    case duplicateInFlight
    case payloadTooLarge(maxBytes: Int)
    case persistenceUnavailable(String?)
    case runtimeUnavailable(String)

    public var wireCode: String {
        switch self {
        case .invalidEnvelope: return "invalidEnvelope"
        case .notFound: return "notFound"
        case .staleRevision: return "staleRevision"
        case .sessionFenced: return "sessionFenced"
        case .duplicateInFlight: return "duplicateInFlight"
        case .payloadTooLarge: return "payloadTooLarge"
        case .persistenceUnavailable: return "persistenceUnavailable"
        case .runtimeUnavailable: return "runtimeUnavailable"
        }
    }

    public var wireReason: String? {
        switch self {
        case .invalidEnvelope(let reason): return reason
        case .notFound: return nil
        case .staleRevision: return nil
        case .sessionFenced(let reason): return reason
        case .duplicateInFlight: return nil
        case .payloadTooLarge(let maxBytes): return "maxBytes:\(maxBytes)"
        case .persistenceUnavailable(let reason): return reason
        case .runtimeUnavailable(let reason): return reason
        }
    }
}

// MARK: - Trusted host context + required service ports

/// Explicit trusted host context. NEVER resolved from "first project",
/// ".tmp", a second database or a model-selected path: the host binder
/// injects the already-accepted owner epoch (reviewed RB1
/// `RuntimeOwnerIdentity.epoch` — RuntimeFacadeStores.swift:157-160) and,
/// only when the product flow genuinely has one, an explicit default shared
/// workspace. `nil` is the honest "no workspace context"; any command that
/// would need a default then fails closed with a typed
/// `runtimeUnavailable`, never a silent pick.
public struct ConversationFacadeContext: Sendable, Equatable {
    public let hostEpoch: UInt64
    public let defaultSharedWorkspaceID: UUID?

    public init(hostEpoch: UInt64, defaultSharedWorkspaceID: UUID? = nil) {
        self.hostEpoch = hostEpoch
        self.defaultSharedWorkspaceID = defaultSharedWorkspaceID
    }
}

/// Exact owned-work evidence for the TARGET conversation.
///
/// Main correction 2026-10-19 (CH-R2): `RuntimeOwnedWorkRegistry
/// .countsByKind(for:)` is a GLOBAL epoch snapshot, not a per-conversation
/// one. A global non-zero count may belong to an unrelated conversation B;
/// blocking A on it (or cancelling B) is wrong. The RB4 owner (job-
/// f6772d4de1584403) therefore maps the target conversation to the EXACT
/// reviewed RB1 tokens it attached for that conversation's real work
/// (pending launches, runs, child runs, tools and final writes) and reports
/// each token together with the real `isAttached` observation taken AFTER
/// its final drain. The deletion operation's own fence/receipt is NOT
/// owned-work evidence and must never appear in this list (that would
/// self-count/self-wait and could deadlock the drain). This file validates
/// that evidence and re-checks the
/// REAL registry synchronously before the destructive commit; it never
/// invents a per-conversation count and never derives one from the global
/// map. Root shutdown/retirement keeps using the global counts unchanged.
public struct ConversationOwnedWorkObservation: Sendable, Equatable {
    /// The conversation the RB4 owner mapped this exact token to. Must be
    /// the target conversation; a foreign value is a hard refusal.
    public let conversationID: UUID
    /// The exact reviewed RB1 token (`work:v1:` receipt, epoch, kind,
    /// ownerID). Receipt shape is validated with
    /// `RuntimeOwnedWorkReceipt.isValid`.
    public let token: RuntimeOwnedWorkToken
    /// The exact `RuntimeOwnedWorkRegistry.shared.isAttached(token)` value
    /// observed after the real drain completed.
    public let stillAttached: Bool

    public init(conversationID: UUID, token: RuntimeOwnedWorkToken,
                stillAttached: Bool) {
        self.conversationID = conversationID
        self.token = token
        self.stillAttached = stillAttached
    }
}

/// Honest report from a REAL per-conversation quiescence implementation.
///
/// `countsEpoch` and `endCountsByKind` are the REAL global
/// `RuntimeOwnedWorkRegistry.countsByKind(for: <accepted epoch>)` snapshot
/// (reviewed RuntimeFacadeBootstrap.swift:1199-1207), observed after the
/// drain. They are retained for honest root/epoch accounting and
/// diagnostics, but they are NOT a gate for this conversation: the global
/// snapshot may legitimately contain an unrelated conversation B's live
/// work, which must neither block nor be cancelled by deleting A. Root
/// retirement still uses those global counts exactly as before.
///
/// The destructive gate is `targetOwnedWork` + `pendingLaunchCount`: the
/// RB4 owner's exact token mapping for THIS conversation, each carrying the
/// real registry `isAttached` result. `nil` evidence is a hard refusal (no
/// default fake zero). An explicit empty list is accepted only as the
/// owner's attestation that this conversation never attached a blocking
/// token. Any still-attached token, foreign conversationID, foreign token
/// epoch, non-blocking kind, duplicate/invalid receipt refuses BEFORE the
/// destructive commit. `vaultMaintenance` is epoch-global and is never
/// target-conversation evidence.
public struct ConversationQuiescenceReport: Sendable, Equatable {
    /// The conversation this report was produced for; must equal the
    /// command target.
    public var conversationID: UUID?
    public var launchesFenced: Bool
    public var inFlightLaunchesAwaited: Int
    public var runServicesCancelled: Int
    public var ownedTasksDrained: Int
    public var childRunsReconciled: Int
    /// Real global registry counts by kind for the accepted epoch. Kept for
    /// root/epoch accounting only; unrelated non-zero kinds do NOT gate this
    /// delete.
    public var endCountsByKind: [String: Int]?
    /// The accepted owner epoch the counts/evidence were read for; must
    /// equal `ConversationFacadeContext.hostEpoch`.
    public var countsEpoch: UInt64?
    /// Exact target-conversation owned-work tokens from the real registry.
    /// `nil` means the implementation did not produce evidence (refused);
    /// `[]` is an explicit "this conversation owned no blocking token".
    public var targetOwnedWork: [ConversationOwnedWorkObservation]?
    /// Pending launch transactions for the TARGET conversation observed
    /// after the fence + drain. `nil` is a hard refusal (no fake zero).
    public var pendingLaunchCount: Int?

    public init(conversationID: UUID? = nil,
                launchesFenced: Bool = false, inFlightLaunchesAwaited: Int = 0,
                runServicesCancelled: Int = 0, ownedTasksDrained: Int = 0,
                childRunsReconciled: Int = 0,
                endCountsByKind: [String: Int]? = nil,
                countsEpoch: UInt64? = nil,
                targetOwnedWork: [ConversationOwnedWorkObservation]? = nil,
                pendingLaunchCount: Int? = nil) {
        self.conversationID = conversationID
        self.launchesFenced = launchesFenced
        self.inFlightLaunchesAwaited = inFlightLaunchesAwaited
        self.runServicesCancelled = runServicesCancelled
        self.ownedTasksDrained = ownedTasksDrained
        self.childRunsReconciled = childRunsReconciled
        self.endCountsByKind = endCountsByKind
        self.countsEpoch = countsEpoch
        self.targetOwnedWork = targetOwnedWork
        self.pendingLaunchCount = pendingLaunchCount
    }

    /// The deletion-blocking kinds: every owned producer whose real work
    /// (and final writes) must have detached before the original DB delete
    /// may run. `vaultMaintenance` is intentionally absent.
    static let deletionBlockingKinds: Set<String> = ["run", "childRun", "tool", "conversation"]

    /// Typed refusal reason for an unusable quiescence report, or nil when
    /// the report genuinely attests the TARGET conversation's owned work is
    /// empty for this epoch. Global counts are deliberately not used as a
    /// blocking predicate (CH-R2).
    func refusalReason(conversationID: UUID, expectedEpoch: UInt64) -> String? {
        guard countsEpoch == expectedEpoch else { return "quiescenceEpochMismatch" }
        guard let counts = endCountsByKind else { return "ownedWorkCountsAbsent" }
        for value in counts.values where value < 0 { return "ownedWorkCountNegative" }
        guard let pending = pendingLaunchCount else { return "pendingLaunchEvidenceAbsent" }
        guard pending == 0 else { return "pendingLaunchesNotDrained" }
        guard let evidence = targetOwnedWork else { return "targetOwnedWorkEvidenceAbsent" }
        guard evidence.count <= RuntimeOwnedWorkRegistry.Limits.maximumLiveWork else {
            return "ownedWorkEvidenceUnbounded"
        }
        var receipts: Set<String> = []
        for item in evidence {
            guard item.conversationID == conversationID else {
                return "ownedWorkForeignConversation"
            }
            guard item.token.epoch == expectedEpoch else {
                return "ownedWorkForeignEpoch"
            }
            guard RuntimeOwnedWorkReceipt.isValid(item.token.receipt) else {
                return "ownedWorkTokenInvalid"
            }
            guard Self.deletionBlockingKinds.contains(item.token.kind.rawValue) else {
                return "ownedWorkUnexpectedKind:\(item.token.kind.rawValue)"
            }
            guard receipts.insert(item.token.receipt).inserted else {
                return "ownedWorkDuplicateToken"
            }
            guard !item.stillAttached else {
                return "ownedWorkNotDrained:\(item.token.kind.rawValue)"
            }
            // Last-safe-point truth: the REAL reviewed registry must also
            // report the exact token detached. Synchronous lock read, never
            // an await and never a timer.
            guard !RuntimeOwnedWorkRegistry.shared.isAttached(item.token) else {
                return "ownedWorkNotDrained:\(item.token.kind.rawValue)"
            }
        }
        return nil
    }
}

/// Typed failures a REAL lifecycle implementation reports to the domain.
/// The domain maps these to the frozen wire vocabulary; adapters never
/// throw raw descriptions into the wire.
public enum ConversationDeletionLifecycleFailure: Error, Sendable, Equatable {
    /// The request's epoch is not the current accepted owner epoch.
    case epochMismatch
    /// Another live deletion operation already owns this conversation guard.
    case fenceHeld
    /// The conversation is absent at the authority.
    case conversationNotFound
    /// The exact operation token is not the current guard (foreign/old).
    case fenceTokenRefused
    /// The real owner could not be reached / is unavailable.
    case ownerUnavailable(String)
    /// The real drain failed; owned work may remain.
    case drainUnavailable(String)
    /// The report could not be produced from real authority.
    case reportUnavailable(String)
}

/// Operation-owned deletion fence. Minted ONLY by `beginDeletionFence`;
/// carries the exact conversation, accepted epoch and operation identity
/// the guard was registered for plus an opaque authority receipt. It is the
/// only value accepted by drain/commit/abort. An old or foreign value can
/// never clear a newer guard because the authority matches the exact token,
/// not the conversation alone.
public struct ConversationDeletionFence: Sendable, Hashable {
    public let conversationID: UUID
    public let epoch: UInt64
    public let operationID: UUID
    /// Opaque real-host receipt for THIS begin call. Never a path, secret or
    /// model-supplied value; must be nonblank.
    public let authorityReceipt: String

    public init(conversationID: UUID, epoch: UInt64, operationID: UUID,
                authorityReceipt: String) {
        self.conversationID = conversationID
        self.epoch = epoch
        self.operationID = operationID
        self.authorityReceipt = authorityReceipt
    }
}

/// Result of settling an operation-owned fence. `released` is the only
/// success; a foreign/old token is refused without touching the current
/// guard; an unavailable authority is reported honestly (post-commit
/// cleanup remains recoverable through the durable queues / next launch).
public enum ConversationDeletionFenceSettlement: Sendable, Equatable {
    case released
    case alreadySettled
    case refusedForeignToken
    case unavailable(String)
}

/// REQUIRED for conversation.delete. The real implementation is the RB4
/// RunDomain adapter (Main coordinator guidance 2026-10-19: job-
/// f6772d4de1584403 owns the actual ConversationRunService/AgentRuntime
/// launch fence, liveTasks, cancel, child+tool drain and the concrete
/// conversation-delete quiescence; RB1 reviewed
/// `MissingBinding.runDomain` stays until then). Until a real instance is
/// bound, delete fails closed with
/// `runtimeUnavailable("conversationDeletionLifecycleUnregistered")` and
/// the row is untouched: there is NO direct SQLite-only delete while owned
/// producers may still be writing, and NO pretend-usable noop.
///
/// The concrete RB4 adapter composes with the REAL reviewed RB1 API:
/// * `RuntimeOwnedWorkRegistry.shared.attach(epoch:kind:ownerID:)`
///   (reviewed :1139) — `.attached(token) / .rejected(RuntimeFacadeCode) /
///   .invalidIdentity`; attach is admitted only for the CURRENT accepted
///   epoch while the owned store is `.ready` and the generation is not
///   draining (attach takes the registry lock then the lifecycle check —
///   reviewed :1146-1154 — so stop blocks NEW attaches while every already
///   admitted attach is observable in the counts).
/// * exact-token `detach(_:)` (:1178) only at REAL completion / final
///   writes — never merely because a caller cancelled, timed out or tore
///   down UI; outstanding ownership survives stop timeout (reviewed R3:
///   failedDrainPending retains owner/database).
/// * The drain returns ONLY when the TARGET conversation's pending
///   launches and exact owned run/childRun/tool/final-write tokens have
///   really settled/detached. It reports those exact tokens plus the REAL
///   registry `isAttached` result; this file re-validates the evidence and
///   re-checks `isAttached` synchronously before the commit. The GLOBAL
///   `countsByKind(for: epoch)` snapshot rides along for root accounting
///   only and must not gate this conversation (CH-R2).
///
/// Explicit operation lifecycle (CH-R3):
/// * `beginDeletionFence` atomically invalidates the per-conversation launch
///   epoch and registers the deleting guard OWNED BY the operationID, so new
///   launches for this conversation are refused and in-flight launch
///   transactions either already committed or fail their own
///   `launchFence.isValid` re-check before prepare
///   (ConversationCenter:3726/:5010/:5045). It refuses when another live
///   operation already holds the guard.
/// * `drainOwnedWork(fence:)` waits for committed pending launches to
///   settle, cancels every owned run service AND owned auxiliary work
///   (children, preprocessing tasks, classifier helpers — the native
///   stopRunsAndDelete set), awaits real completion, and produces the
///   honest per-conversation report above. It never detaches owned-work
///   tokens on caller cancel/timeout and never releases on a timer.
/// * The adapter must never attach the deletion operation itself as
///   target owned work and must never wait for its own fence; the fence is
///   a guard, not a drain participant (CH-R2 self-count rule).
/// * The CALLER invokes exactly one of `commitDeletionFence` (only after
///   the original DB commit) or `abortDeletionFence` (every other
///   exit — throw, cancellation, stale, drain failure). Both are exact
///   token settlements: a foreign/old token returns
///   `.refusedForeignToken` and cannot clear a newer guard. Abort releases
///   only the guard; the surviving conversation can launch again once the
///   REAL remaining owned work has settled.
/// * Cancellation of the CALLING delete job is honoured ONLY BEFORE the DB
///   commit (rows intact; the caller abort clears OUR guard). After commit,
///   cleanup completes best-effort and the reply carries honest partial
///   status (native comment :5972-5973: "A cleanup failure can occur after
///   the task transaction committed").
/// * ORDINARY navigation (list/get/messagePage/search/archive/rename)
///   NEVER calls this port — archive is not a cancel; an ordinary run
///   continues under its service owner.
public protocol ConversationDeletionLifecycle: Sendable {
    func beginDeletionFence(conversationID: UUID, epoch: UInt64,
                            operationID: UUID) async throws -> ConversationDeletionFence
    func drainOwnedWork(fence: ConversationDeletionFence) async throws
        -> ConversationQuiescenceReport
    func abortDeletionFence(_ fence: ConversationDeletionFence) async
        -> ConversationDeletionFenceSettlement
    func commitDeletionFence(_ fence: ConversationDeletionFence) async
        -> ConversationDeletionFenceSettlement
}

/// Credential-deletion drain summary. `deferredCount` is the durable queue
/// depth the implementation chose to leave for the restart/recovery drain
/// (honest deferral), `failedCount` its observed real failures. `nil` means
/// the bound implementation does not surface a count — never fabricated.
public struct CredentialDeletionDrainSummary: Sendable, Equatable {
    public var drained: Int?
    public var deferredCount: Int?
    public var failedCount: Int?

    public init(drained: Int?, deferredCount: Int?, failedCount: Int?) {
        self.drained = drained
        self.deferredCount = deferredCount
        self.failedCount = failedCount
    }
}

/// Optional-but-truthful binding point for the accepted RB-2b vault.
/// `AndroidCredentialVault.drainDeletionQueue()`
/// (runtime-credential-vault-recovery-source candidate :786, returning
/// `CredentialDeletionDrainReport`) is the real target; the integration
/// adapter maps its report into the neutral summary above and composes with
/// the vault-07 owned-work accounting (`RuntimeOwnedWorkKind
/// .vaultMaintenance`) per Main's reconciliation note. The V11
/// `credential_delete_queue` BEFORE DELETE trigger
/// (FloePersistence/Migrations/V11ArchiveCredentials.swift:55-65) commits
/// the durable secret-removal intent INSIDE the conversation delete
/// transaction; without a bound vault the queue rows simply survive
/// (process-death recoverable) and the reply says `.deferredUnbound`.
public protocol ConversationCredentialDeletionDraining: Sendable {
    func drainDeletionQueue() async -> CredentialDeletionDrainSummary
}

/// Removes ONE already-queued private-task workspace directory tree inside
/// the trusted host-owned application root. The real implementation mirrors
/// WorkspaceCenter.removePrivateWorkspaceDirectory
/// (FloeApp/Workspace/WorkspaceCenter.swift:423-443): the relative path must
/// be exactly `PrivateTasks/<uuid>`, the target must resolve inside the
/// canonical managed root with no symlink escape, and the durable
/// bookkeeping stays on the ORIGINAL store APIs (pendingLocalCleanup /
/// workspace(id:) / conversations(workspaceID:) / deleteWorkspace /
/// finishLocalCleanup), which this adapter already drives. The port exists
/// ONLY for the host-filesystem removal the facade has no entitlement for.
/// Unbound → the V36 trigger-queued rows survive and the reply reports
/// `.deferredQueueRetained`.
public protocol ConversationOwnedWorkspaceCleaning: Sendable {
    func removePrivateTaskDirectory(relativePath: String) async throws
}

// MARK: - Closed request values

public struct BaseRevision: Sendable, Equatable {
    public let resourceID: String
    public let version: String
    public init(resourceID: String, version: String) {
        self.resourceID = resourceID
        self.version = version
    }
}

public struct ConversationListQuery: Sendable, Equatable {
    public var includeArchived = false
    public var cursor: String? = nil
    public var includeRevision = false
    public var limit: Int = ConversationListQuery.defaultLimit

    /// Mirrors the original ConversationListRequest bound
    /// (ConversationHistoryContracts.swift:60-63): default 20, clamp 1...50.
    public static let defaultLimit = 20
    public static let maximumLimit = 50

    public init() {}

    /// Closed payload grammar. Unknown keys, wrong types, out-of-range
    /// limits and malformed cursors are typed invalidEnvelope and NEVER
    /// reach the database.
    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> ConversationListQuery
    {
        var query = ConversationListQuery()
        guard let payload else { return query }
        guard case .object(let root) = payload else {
            throw ConversationDomainError.invalidEnvelope("invalidPayload")
        }
        for key in root.keys where !["includeArchived", "cursor", "limit",
                                     "includeRevision"].contains(key) {
            throw ConversationDomainError.invalidEnvelope("unknownListField")
        }
        if let value = root["includeArchived"] {
            guard case .boolean(let flag) = value else {
                throw ConversationDomainError.invalidEnvelope("invalidPayloadField:includeArchived")
            }
            query.includeArchived = flag
        }
        if let value = root["includeRevision"] {
            guard case .boolean(let flag) = value else {
                throw ConversationDomainError.invalidEnvelope("invalidPayloadField:includeRevision")
            }
            query.includeRevision = flag
        }
        if let value = root["cursor"] {
            guard case .string(let raw) = value else {
                throw ConversationDomainError.invalidEnvelope("invalidPayloadField:cursor")
            }
            query.cursor = raw
        }
        if let value = root["limit"] {
            guard case .integer(let raw) = value else {
                throw ConversationDomainError.invalidEnvelope("invalidPayloadField:limit")
            }
            query.limit = try clampedLimit(raw, field: "limit")
        }
        return query
    }

    static func clampedLimit(_ raw: Int64, field: String) throws -> Int {
        guard raw >= 1, raw <= Int64(maximumLimit) else {
            throw ConversationDomainError.invalidEnvelope("payloadFieldOutOfRange:\(field)")
        }
        return Int(raw)
    }
}

public struct ConversationSearchQuery: Sendable, Equatable {
    public var request: ConversationSearchRequest

    /// The ORIGINAL request value type is built here, so its own clamp
    /// (ConversationHistoryContracts.swift:23 `min(50, max(1, limit))`) is
    /// the authority — no second cap.
    public init(request: ConversationSearchRequest) { self.request = request }

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> ConversationSearchQuery
    {
        guard let payload else {
            throw ConversationDomainError.invalidEnvelope("missingPayload")
        }
        guard case .object(let root) = payload else {
            throw ConversationDomainError.invalidEnvelope("invalidPayload")
        }
        for key in root.keys where !["query", "workspaceID", "startDate",
                                     "endDate", "limit", "includeAllWorkspaces"]
            .contains(key) {
            throw ConversationDomainError.invalidEnvelope("unknownSearchField")
        }
        guard case .string(let queryText)? = root["query"] else {
            throw ConversationDomainError.invalidEnvelope("missingPayloadField:query")
        }
        var workspaceID: UUID?
        if let value = root["workspaceID"] {
            guard case .string(let raw) = value, let id = UUID(uuidString: raw) else {
                throw ConversationDomainError.invalidEnvelope("invalidPayloadField:workspaceID")
            }
            workspaceID = id
        }
        let startDate = try optionalDate(root["startDate"], field: "startDate")
        let endDate = try optionalDate(root["endDate"], field: "endDate")
        var limit = 20
        if let value = root["limit"] {
            guard case .integer(let raw) = value, raw >= 1, raw <= 50 else {
                throw ConversationDomainError.invalidEnvelope("invalidPayloadField:limit")
            }
            limit = Int(raw)
        }
        var includeAll = false
        if let value = root["includeAllWorkspaces"], case .boolean(let flag) = value {
            includeAll = flag
        }
        return ConversationSearchQuery(request: ConversationSearchRequest(
            query: queryText,
            workspaceID: workspaceID,
            startDate: startDate,
            endDate: endDate,
            limit: limit,
            includeAllWorkspaces: includeAll
        ))
    }

    /// Dates on the wire use the SAME persisted codec grammar as the stores
    /// (ISO-8601 internet date-time, optional fractional seconds).
    static func optionalDate(_ value: SettingsDomainV1.JSONValue?, field: String) throws -> Date? {
        guard let value else { return nil }
        guard case .string(let raw) = value else {
            throw ConversationDomainError.invalidEnvelope("invalidPayloadField:\(field)")
        }
        return try ConversationWireDate.decodeStrict(raw, field: field)
    }
}

public struct ConversationMessagePageQuery: Sendable, Equatable {
    public var cursor: ConversationMessageCursor?
    public var limit: Int = ConversationMessagePageQuery.defaultLimit

    /// The snapshot first-screen size is native (sessionSnapshot messagePage
    /// limit 20 — ConversationCenter:1401-1403); the hard cap mirrors the
    /// ORIGINAL store bound (messagePage `min(500, …)` —
    /// ConversationStore.swift:486). No new arbitrary cap.
    public static let defaultLimit = 20
    public static let maximumLimit = 500

    public init() {}

    public static func parse(_ payload: SettingsDomainV1.JSONValue?,
                             decodeCursor: (String) throws -> ConversationMessageCursor?) throws
        -> ConversationMessagePageQuery
    {
        var query = ConversationMessagePageQuery()
        guard let payload else { return query }
        guard case .object(let root) = payload else {
            throw ConversationDomainError.invalidEnvelope("invalidPayload")
        }
        for key in root.keys where ["before", "limit"].contains(key) == false {
            throw ConversationDomainError.invalidEnvelope("unknownMessagePageField")
        }
        if let value = root["before"] {
            guard case .string(let raw) = value else {
                throw ConversationDomainError.invalidEnvelope("invalidPayloadField:before")
            }
            query.cursor = try decodeCursor(raw)
        }
        if let value = root["limit"] {
            guard case .integer(let raw) = value, raw >= 1, raw <= Int64(maximumLimit) else {
                throw ConversationDomainError.invalidEnvelope("invalidPayloadField:limit")
            }
            query.limit = Int(raw)
        }
        return query
    }
}

public struct ConversationCreateQuery: Sendable, Equatable {
    public var title: String?

    /// Rename's native cap is the strictest conversation title policy
    /// (ConversationCenter.renameConversation:5981-5988 trims then
    /// `prefix(120)`); the facade REFUSES above the cap instead of silently
    /// truncating, so a created title can always be renamed back to itself.
    /// Create keeps native tolerance for empty/absent titles: blank ordinary
    /// rows are the verified-empty contract of
    /// deleteConversationIfVerifiedEmpty (:289-376) and of
    /// TemporaryChat in-place promotion.
    public static let maximumTitleLength = 120

    public init(title: String? = nil) { self.title = title }

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> ConversationCreateQuery
    {
        guard let payload else { return ConversationCreateQuery() }
        guard case .object(let root) = payload else {
            throw ConversationDomainError.invalidEnvelope("invalidPayload")
        }
        // purpose is NOT a payload field: ordinary-only creation is fixed in
        // the commit mirror and re-checked on read-back. Notes/attachment-
        // staging/temporary identities are owned by their own lanes.
        for key in root.keys where key != "title" {
            throw ConversationDomainError.invalidEnvelope("unknownCreateField")
        }
        if let value = root["title"] {
            guard case .string(let raw) = value else {
                throw ConversationDomainError.invalidEnvelope("invalidPayloadField:title")
            }
            guard raw.count <= Self.maximumTitleLength else {
                throw ConversationDomainError.invalidEnvelope("payloadFieldTooLong:title")
            }
            return ConversationCreateQuery(title: raw)
        }
        return ConversationCreateQuery()
    }
}

public struct ConversationRenameQuery: Sendable, Equatable {
    public var title: String

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> ConversationRenameQuery
    {
        guard let payload else {
            throw ConversationDomainError.invalidEnvelope("missingPayload")
        }
        guard case .object(let root) = payload else {
            throw ConversationDomainError.invalidEnvelope("invalidPayload")
        }
        for key in root.keys where key != "title" {
            throw ConversationDomainError.invalidEnvelope("unknownRenameField")
        }
        guard case .string(let raw)? = root["title"] else {
            throw ConversationDomainError.invalidEnvelope("missingPayloadField:title")
        }
        // Native normalization, applied BEFORE any mutation:
        // trimmingCharacters(.whitespacesAndNewlines), empty refusal,
        // prefix(120) — ConversationCenter:5982-5988.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConversationDomainError.invalidEnvelope("emptyTitle")
        }
        return ConversationRenameQuery(
            title: String(trimmed.prefix(ConversationCreateQuery.maximumTitleLength)))
    }
}

public struct ConversationArchiveQuery: Sendable, Equatable {
    public var archived: Bool

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> ConversationArchiveQuery
    {
        guard let payload else {
            throw ConversationDomainError.invalidEnvelope("missingPayload")
        }
        guard case .object(let root) = payload else {
            throw ConversationDomainError.invalidEnvelope("invalidPayload")
        }
        for key in root.keys where key != "archived" {
            throw ConversationDomainError.invalidEnvelope("unknownArchiveField")
        }
        guard case .boolean(let flag)? = root["archived"] else {
            throw ConversationDomainError.invalidEnvelope("missingPayloadField:archived")
        }
        return ConversationArchiveQuery(archived: flag)
    }
}

// MARK: - Wire date helper

/// Local mirror of the two PURE PersistenceCodec format lines (the original
/// codec is internal to FloePersistence; mirroring pure formatting edits no
/// shared source and cannot drift the stored representation because every
/// store writer uses exactly this format):
/// `ISO8601DateFormatter [.withInternetDateTime, .withFractionalSeconds]`,
/// with the same tolerant read-back (fractional, then plain internet
/// date-time) as PersistenceCodec.decodeDate (:15-25).
public enum ConversationWireDate {
    public static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func decode(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    /// Strict typed decode for closed payloads.
    static func decodeStrict(_ value: String, field: String) throws -> Date {
        guard let date = decode(value) else {
            throw ConversationDomainError.invalidEnvelope("invalidPayloadField:\(field)")
        }
        return date
    }
}

// MARK: - Opaque keyset cursors

/// `k1.` URL-safe-base64 JSON cursor — the proven convention from
/// IntelligenceStore.encodeTimelineCursor/decodeTimelineCursor (:1263-1288).
/// The list cursor carries the RAW persisted `updated_at` string plus the
/// row UUID; the message cursor carries the codec-encoded `created_at`
/// string (the exact value the store itself binds at :494) plus the message
/// UUID. JSON length-prefixed structure (not a delimiter join) makes
/// injected delimiters impossible to alias, and carrying raw strings means
/// a page boundary can never shift under re-decoding.
enum ConversationCursorCodec {
    static let prefix = "k1."

    struct ListPayload: Codable { let updatedAt: String; let id: String }
    struct MessagePayload: Codable { let createdAt: String; let id: String }

    static func encodeList(_ payload: ListPayload) throws -> String {
        try wrap(payload)
    }
    static func encodeMessage(_ payload: MessagePayload) throws -> String {
        try wrap(payload)
    }
    static func decodeList(_ raw: String) throws -> ListPayload? {
        try unwrap(raw, ListPayload.self)
    }
    static func decodeMessage(_ raw: String) throws -> MessagePayload? {
        try unwrap(raw, MessagePayload.self)
    }

    private static func wrap<T: Encodable>(_ payload: T) throws -> String {
        let data = try JSONEncoder().encode(payload)
        // Qualifier repair (2026-10-19): the unwrap side base64url-decodes
        // (opaque token contract); encode must actually base64url-ENCODE the
        // JSON. The previous code JSON-encoded and only renamed characters,
        // so every minted cursor was rejected on the next page.
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard !encoded.isEmpty else {
            throw ConversationDomainError.persistenceUnavailable("cursorEncode")
        }
        return prefix + encoded
    }

    private static func unwrap<T: Decodable>(_ raw: String, _ type: T.Type) throws -> T? {
        guard raw.hasPrefix(prefix) else {
            throw ConversationDomainError.invalidEnvelope("invalidCursor")
        }
        var encoded = String(raw.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else {
            throw ConversationDomainError.invalidEnvelope("invalidCursor")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ConversationDomainError.invalidEnvelope("invalidCursor")
        }
    }
}

// MARK: - Reply values

/// One ordinary-conversation list row. `updatedAt` carries the RAW persisted
/// codec string so keyset continuation is byte-exact; `revision` is present
/// only when the caller explicitly asked (`includeRevision`) and only from
/// the real same-transaction read — "Publish version only from actual
/// producer reads" (RB3 admission).
public struct ConversationListRow: Sendable, Equatable {
    public let conversationID: UUID
    public let title: String
    public let updatedAtRaw: String
    public let archivedAtRaw: String?
    public let revision: String?

    public init(conversationID: UUID, title: String, updatedAtRaw: String,
                archivedAtRaw: String?, revision: String?) {
        self.conversationID = conversationID
        self.title = title
        self.updatedAtRaw = updatedAtRaw
        self.archivedAtRaw = archivedAtRaw
        self.revision = revision
    }

    public var wireObject: [String: Any] {
        var object: [String: Any] = [
            "conversationID": conversationID.uuidString,
            "title": title,
            "updatedAt": updatedAtRaw,
            "archived": archivedAtRaw != nil,
        ]
        object["revision"] = revision ?? NSNull()
        return object
    }
}

public struct ConversationListReply: Sendable, Equatable {
    public let rows: [ConversationListRow]
    /// Opaque `k1.` keyset cursor over (updated_at, id) in the native
    /// `ORDER BY updated_at DESC, id` order. nil when nothing follows.
    public let nextCursor: String?
    public let hasMore: Bool

    public init(rows: [ConversationListRow], nextCursor: String?, hasMore: Bool) {
        self.rows = rows
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }

    public var wireObject: [String: Any] {
        [
            "rows": rows.map(\.wireObject),
            "nextCursor": nextCursor ?? NSNull(),
            "hasMore": hasMore,
        ]
    }
}

public struct ConversationSearchRow: Sendable, Equatable {
    public let conversationID: UUID
    public let messageID: UUID
    public let workspaceID: UUID?
    public let conversationTitle: String
    public let snippet: String
    public let createdAtRaw: String

    public init(conversationID: UUID, messageID: UUID, workspaceID: UUID?,
                conversationTitle: String, snippet: String, createdAtRaw: String) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.workspaceID = workspaceID
        self.conversationTitle = conversationTitle
        self.snippet = snippet
        self.createdAtRaw = createdAtRaw
    }

    /// Native hits preview via FTS `snippet(...,24)` / `substr(...,180)` /
    /// "[title match]" prefixes (IntelligenceStore:1048/:1463/:1546). A
    /// preview is allowed because the FULL content stays reachable through
    /// `conversation.messagePage` and the owned `content.read` handle path —
    /// nothing here relabels a prefix as complete.
    public var wireObject: [String: Any] {
        var object: [String: Any] = [
            "conversationID": conversationID.uuidString,
            "messageID": messageID.uuidString,
            "conversationTitle": conversationTitle,
            "snippet": snippet,
            "createdAt": createdAtRaw,
        ]
        // Explicit JSON null when the row carries no workspace (never a
        // boxed Optional.none: strict G02DomainBinder.designValue refuses
        // unknown values and the carrier must deliver the real null).
        object["workspaceID"] = workspaceID?.uuidString ?? NSNull()
        return object
    }
}

public struct ConversationSearchReply: Sendable, Equatable {
    public let rows: [ConversationSearchRow]
    /// True count of original-store hits the reply does NOT carry, from
    /// either the store limit or the page-budget trim (trailing relevance/
    /// recency rows only — native source order is preserved, nothing is
    /// reordered or invented). The original search has no cursor; the client
    /// narrows query/filters. `0` means the reply is the complete result set.
    public let truncatedTailCount: Int

    public init(rows: [ConversationSearchRow], truncatedTailCount: Int) {
        self.rows = rows
        self.truncatedTailCount = truncatedTailCount
    }

    public var wireObject: [String: Any] {
        [
            "rows": rows.map(\.wireObject),
            "truncatedTail": truncatedTailCount,
        ]
    }
}

public struct ConversationMessageRowWire: Sendable, Equatable {
    public let messageID: UUID
    /// The role is forwarded EXACTLY as stored. The original durable writers
    /// persist "user", "assistant", "system" (ConversationCenter:3463/:3566),
    /// and "goalContinuation" is a first-class durable prompt role
    /// (RunLaunchStore:135 validates user|goalContinuation). Any other stored
    /// role string passes through unchanged: tool/system/unknown rows are
    /// NEVER renamed to "assistant" and never silently dropped.
    public let role: String
    public let createdAtRaw: String
    public let runID: UUID?
    public let content: String?
    public let contentHandle: String?
    public let totalBytes: Int
    /// False ONLY when the full content moved to the owned `contentHandle`
    /// (nothing inline). True ONLY for the COMPLETE inline content. A
    /// partial inline is never produced by this builder.
    public let contentInlineComplete: Bool
    public let partCount: Int

    public init(messageID: UUID, role: String, createdAtRaw: String, runID: UUID?,
                content: String?, contentHandle: String?, totalBytes: Int,
                contentInlineComplete: Bool, partCount: Int) {
        self.messageID = messageID
        self.role = role
        self.createdAtRaw = createdAtRaw
        self.runID = runID
        self.content = content
        self.contentHandle = contentHandle
        self.totalBytes = totalBytes
        self.contentInlineComplete = contentInlineComplete
        self.partCount = partCount
    }

    public var wireObject: [String: Any] {
        var object: [String: Any] = [
            "id": messageID.uuidString,
            "role": role,
            "createdAt": createdAtRaw,
            "totalBytes": totalBytes,
            "partCount": partCount,
            "content": content ?? NSNull(),
            "contentHandle": contentHandle ?? NSNull(),
            "contentInlineComplete": contentInlineComplete,
        ]
        // Explicit JSON null for a message with no owning run (same
        // invariant as the file's other `?? NSNull()` projections).
        object["runID"] = runID?.uuidString ?? NSNull()
        return object
    }
}

public struct ConversationMessagePageReply: Sendable, Equatable {
    public var rows: [ConversationMessageRowWire]
    public var earlierCursor: String?
    public var hasEarlier: Bool
    /// True when at least one row used an owned content handle.
    public var usesContentHandles: Bool

    public init(rows: [ConversationMessageRowWire], earlierCursor: String?,
                hasEarlier: Bool, usesContentHandles: Bool) {
        self.rows = rows
        self.earlierCursor = earlierCursor
        self.hasEarlier = hasEarlier
        self.usesContentHandles = usesContentHandles
    }

    public var wireObject: [String: Any] {
        [
            "rows": rows.map(\.wireObject),
            "earlierCursor": earlierCursor ?? NSNull(),
            "hasEarlier": hasEarlier,
            "usesContentHandles": usesContentHandles,
        ]
    }
}

/// The honest `conversation.get` field set: the ConversationSessionSnapshot
/// fields (:704-718) MINUS live run state (eventsByRun/pendingApprovals —
/// RB4 durable-event/live channel), minus the UI-coalescing `revision: Int`
/// counter (not a domain value), plus the opaque row digest. Plan/checklist/
/// goal fields belong to the later plan/goal lanes and are OMITTED, not
/// faked (G02 whole remains).
public struct ConversationSessionReply: Sendable, Equatable {
    public let conversationID: UUID
    public let resourceID: String
    public let revision: String
    public let title: String
    public let createdAtRaw: String
    public let updatedAtRaw: String
    public let titleOrigin: String
    public let archivedAtRaw: String?
    public let firstScreen: ConversationMessagePageReply
    public let messagesTotalCount: Int
    public let runs: [ConversationRunSummaryWire]
    public let runsTotalCount: Int
    public let runsTruncated: Bool
    public let pendingInputs: [PendingUserInputWire]
    public let pendingInputsTotalCount: Int
    public let pendingInputsTruncated: Bool
    public let taskPolicy: TaskPolicy

    public init(conversationID: UUID, resourceID: String, revision: String,
                title: String, createdAtRaw: String, updatedAtRaw: String,
                titleOrigin: String, archivedAtRaw: String?,
                firstScreen: ConversationMessagePageReply,
                messagesTotalCount: Int,
                runs: [ConversationRunSummaryWire], runsTotalCount: Int,
                runsTruncated: Bool,
                pendingInputs: [PendingUserInputWire],
                pendingInputsTotalCount: Int, pendingInputsTruncated: Bool,
                taskPolicy: TaskPolicy) {
        self.conversationID = conversationID
        self.resourceID = resourceID
        self.revision = revision
        self.title = title
        self.createdAtRaw = createdAtRaw
        self.updatedAtRaw = updatedAtRaw
        self.titleOrigin = titleOrigin
        self.archivedAtRaw = archivedAtRaw
        self.firstScreen = firstScreen
        self.messagesTotalCount = messagesTotalCount
        self.runs = runs
        self.runsTotalCount = runsTotalCount
        self.runsTruncated = runsTruncated
        self.pendingInputs = pendingInputs
        self.pendingInputsTotalCount = pendingInputsTotalCount
        self.pendingInputsTruncated = pendingInputsTruncated
        self.taskPolicy = taskPolicy
    }

    public var wireObject: [String: Any] {
        var object: [String: Any] = [
            "conversationID": conversationID.uuidString,
            "resourceID": resourceID,
            "revision": revision,
            "title": title,
            "createdAt": createdAtRaw,
            "updatedAt": updatedAtRaw,
            "titleOrigin": titleOrigin,
            "purpose": ConversationPurpose.ordinary.rawValue,
            "firstScreen": firstScreen.wireObject,
            "messagesTotalCount": messagesTotalCount,
            "runs": runs.map(\.wireObject),
            "runsTotalCount": runsTotalCount,
            "runsTruncated": runsTruncated,
            "pendingInputs": pendingInputs.map(\.wireObject),
            "pendingInputsTotalCount": pendingInputsTotalCount,
            "pendingInputsTruncated": pendingInputsTruncated,
            "taskPolicy": taskPolicy.wireProjection,
        ]
        // A fresh (unarchived) conversation carries JSON null — the exact
        // original string when archived. `archivedAtRaw as Any` boxed
        // Optional.none, which strict designValue cannot convert: the whole
        // fresh snapshot settled frameBudgetExceeded (device-proven 2026-10-20).
        object["archivedAt"] = archivedAtRaw ?? NSNull()
        return object
    }
}

/// Bounded pending-input projection. Content bytes are reported as an
/// ACTUAL UTF-8 length (no excerpt text is inlined into the snapshot: the
/// queue content belongs to the message/event lanes). Attachment lists
/// surface counts only — binary/URI ingress is P8.
public struct PendingUserInputWire: Sendable, Equatable {
    public let id: UUID
    public let mode: String
    public let status: String
    public let position: Int64
    public let targetRunID: UUID?
    public let createdAtRaw: String
    public let contentUTF8Bytes: Int
    public let attachmentCount: Int

    public init(input: PendingUserInput) {
        self.id = input.id
        self.mode = input.mode.rawValue
        self.status = input.status.rawValue
        self.position = input.position
        self.targetRunID = input.targetRunID
        self.createdAtRaw = ConversationWireDate.encode(input.createdAt)
        self.contentUTF8Bytes = input.content.utf8.count
        self.attachmentCount = input.attachments.count
    }

    public var wireObject: [String: Any] {
        var object: [String: Any] = [
            "id": id.uuidString,
            "mode": mode,
            "status": status,
            "position": position,
            "createdAt": createdAtRaw,
            "contentBytes": contentUTF8Bytes,
            "attachmentCount": attachmentCount,
        ]
        object["targetRunID"] = targetRunID?.uuidString ?? NSNull()
        return object
    }
}

public struct ConversationRunSummaryWire: Sendable, Equatable {
    public let runID: UUID
    public let state: String
    public let startedAtRaw: String
    public let endedAtRaw: String?
    public let providerName: String?
    public let modelName: String?
    public let conversationMode: String?

    public init(runID: UUID, state: String, startedAtRaw: String, endedAtRaw: String?,
                providerName: String?, modelName: String?, conversationMode: String?) {
        self.runID = runID
        self.state = state
        self.startedAtRaw = startedAtRaw
        self.endedAtRaw = endedAtRaw
        self.providerName = providerName
        self.modelName = modelName
        self.conversationMode = conversationMode
    }

    /// `goal` text is deliberately NOT part of the snapshot run summaries:
    /// full history belongs to the message/event lanes, and inlining goals
    /// blew the page budget on long tasks. Absence is honest (no fabricated
    /// excerpt).
    public var wireObject: [String: Any] {
        var object: [String: Any] = [
            "runID": runID.uuidString,
            "state": state,
            "startedAt": startedAtRaw,
        ]
        object["endedAt"] = endedAtRaw ?? NSNull()
        object["providerName"] = providerName ?? NSNull()
        object["modelName"] = modelName ?? NSNull()
        object["conversationMode"] = conversationMode ?? NSNull()
        return object
    }
}

extension TaskPolicy {
    /// Closed projection of the ORIGINAL TaskPolicy
    /// (FloeModels/TaskPolicy.swift:104-125). `allowedToolNames`/`filePaths`
    /// are reported as counts in the snapshot body — their full content is
    /// policy-editor (run.policy.update, RB4) territory; the counts are
    /// real, never silent absence.
    var wireProjection: [String: Any] {
        var object: [String: Any] = [
            "approvalMode": approvalMode ?? NSNull(),
            "resolvedApprovalMode": resolvedApprovalMode.rawValue,
            "recoveryPolicy": recoveryPolicy.rawValue,
            "notificationPolicy": notificationPolicy.rawValue,
            "networkAllowed": networkAllowed ?? NSNull(),
            "browserControlAllowed": browserControlAllowed ?? NSNull(),
            "uploadAllowed": uploadAllowed ?? NSNull(),
            "credentialsAllowed": credentialsAllowed ?? NSNull(),
            "remoteExecutionAllowed": remoteExecutionAllowed ?? NSNull(),
            "filePathCount": filePaths.count,
            "updatedAt": ConversationWireDate.encode(updatedAt),
        ]
        // Absent whitelist (nil) and empty whitelist ({}) are distinguishable.
        object["allowedToolNameCount"] = allowedToolNames.map { $0.count } ?? NSNull()
        return object
    }
}

public struct ConversationCreateReply: Sendable, Equatable {
    public let conversationID: UUID
    public let resourceID: String
    /// The digest of the row READ BACK inside the same commit transaction.
    public let revision: String
    public let title: String
    public let createdAtRaw: String
    public let updatedAtRaw: String

    public init(conversationID: UUID, resourceID: String, revision: String,
                title: String, createdAtRaw: String, updatedAtRaw: String) {
        self.conversationID = conversationID
        self.resourceID = resourceID
        self.revision = revision
        self.title = title
        self.createdAtRaw = createdAtRaw
        self.updatedAtRaw = updatedAtRaw
    }

    /// The committed identity for the async `prepared` effect. The queue
    /// receipt itself (RB1 `op:v1:` token) is minted by the mailbox at
    /// submit and carries NO domain id (BRIDGE_V3_MAIN_DECISIONS
    /// .asynchronous); this value only exists after the atomic commit.
    public var wireObject: [String: Any] {
        [
            "conversationID": conversationID.uuidString,
            "resourceID": resourceID,
            "revision": revision,
            "title": title,
            "createdAt": createdAtRaw,
            "updatedAt": updatedAtRaw,
        ]
    }
}

public struct ConversationMutationReply: Sendable, Equatable {
    public let conversationID: UUID
    public let resourceID: String
    /// New full-row digest, returned ONLY after the commit returned.
    public let revision: String

    public init(conversationID: UUID, resourceID: String, revision: String) {
        self.conversationID = conversationID
        self.resourceID = resourceID
        self.revision = revision
    }

    public var wireObject: [String: Any] {
        [
            "conversationID": conversationID.uuidString,
            "resourceID": resourceID,
            "revision": revision,
        ]
    }
}

public enum ConversationDeleteCleanupStatus: Sendable, Equatable {
    case none
    case removed
    /// The V36 queue row is retained durably; a bound cleaning
    /// implementation or `retryPendingLocalWorkspaceCleanup` completes it
    /// later. Honest deferral, never a fake success.
    case deferredQueueRetained(String)
    case failed(String)
}

public enum ConversationCredentialDrainStatus: Sendable, Equatable {
    case drained(CredentialDeletionDrainSummary)
    /// V11 queue rows survive inside the SAME committed transaction; the
    /// restart/recovery drain consumes them once the vault is bound.
    case deferredUnbound
}

public struct ConversationDeleteReply: Sendable, Equatable {
    public let conversationID: UUID
    public let quiescence: ConversationQuiescenceReport
    public let workspaceCleanup: ConversationDeleteCleanupStatus
    public let credentialDrain: ConversationCredentialDrainStatus
    public let contentHandlesReleased: Int
    /// Exact-token settlement of the operation-owned fence AFTER the DB
    /// commit. `.released` is the clean case; `.alreadySettled` is
    /// idempotent; `.refusedForeignToken`/`.unavailable` are reported
    /// honestly (the row is already committed; the guard/authority outcome
    /// remains diagnosable and recoverable).
    public let fenceSettlement: ConversationDeletionFenceSettlement

    public init(conversationID: UUID, quiescence: ConversationQuiescenceReport,
                workspaceCleanup: ConversationDeleteCleanupStatus,
                credentialDrain: ConversationCredentialDrainStatus,
                contentHandlesReleased: Int,
                fenceSettlement: ConversationDeletionFenceSettlement) {
        self.conversationID = conversationID
        self.quiescence = quiescence
        self.workspaceCleanup = workspaceCleanup
        self.credentialDrain = credentialDrain
        self.contentHandlesReleased = contentHandlesReleased
        self.fenceSettlement = fenceSettlement
    }

    public var wireObject: [String: Any] {
        var object: [String: Any] = [
            "conversationID": conversationID.uuidString,
            "launchesFenced": quiescence.launchesFenced,
            "inFlightLaunchesAwaited": quiescence.inFlightLaunchesAwaited,
            "runServicesCancelled": quiescence.runServicesCancelled,
            "ownedTasksDrained": quiescence.ownedTasksDrained,
            "childRunsReconciled": quiescence.childRunsReconciled,
            "pendingLaunchCount": quiescence.pendingLaunchCount ?? NSNull(),
            "targetOwnedWorkTokens": quiescence.targetOwnedWork?.count ?? NSNull(),
            "contentHandlesReleased": contentHandlesReleased,
        ]
        switch fenceSettlement {
        case .released: object["fenceSettlement"] = "released"
        case .alreadySettled: object["fenceSettlement"] = "alreadySettled"
        case .refusedForeignToken: object["fenceSettlement"] = "refusedForeignToken"
        case .unavailable(let reason):
            object["fenceSettlement"] = "unavailable"
            object["fenceSettlementReason"] = reason
        }
        switch workspaceCleanup {
        case .none: object["workspaceCleanup"] = "none"
        case .removed: object["workspaceCleanup"] = "removed"
        case .deferredQueueRetained(let reason):
            object["workspaceCleanup"] = "deferredQueueRetained"
            object["workspaceCleanupReason"] = reason
        case .failed(let reason):
            object["workspaceCleanup"] = "failed"
            object["workspaceCleanupReason"] = reason
        }
        switch credentialDrain {
        case .drained(let summary):
            object["credentialDrain"] = "drained"
            object["credentialDrained"] = summary.drained ?? NSNull()
            object["credentialDeferred"] = summary.deferredCount ?? NSNull()
        case .deferredUnbound:
            object["credentialDrain"] = "deferredQueueRetained"
        }
        return object
    }
}

// MARK: - Handler binding plan (documentation for the future binder)

/// The EXACT v3 handler keys this domain is designed to serve, computed
/// with the LIVE frozen helper `BridgeV3.handlerKey(scope:command:)`. This
/// plan registers NOTHING. Integration rule (RB3 admission + P0 handoff):
/// the `applicationConfiguration` `content.read` key is SHARED and must be
/// composed by `configurationScope` — the personalization lane has added a
/// third `content.read` rule under the SAME handler key. A future binder
/// must fan out on the label and never let one lane replace the other's
/// processor; this package must never be cited as a third command name.
public enum ConversationDomainHandlerPlan {
    public struct Binding: Sendable, Equatable {
        public let handlerKey: String
        public let command: String
        public let scope: BridgeV3.Scope
        public let configurationScope: String?
        public let serviceMethod: String
        public let integrationNote: String
    }

    public static var bindings: [Binding] {
        [
            Binding(
                handlerKey: BridgeV3.handlerKey(scope: .applicationConfiguration,
                                                 command: "conversation.list"),
                command: "conversation.list",
                scope: .applicationConfiguration,
                configurationScope: "conversations",
                serviceMethod: "FacadeConversationDomain.list",
                integrationNote: "completed{page} pure read; label must be 'conversations'"
            ),
            Binding(
                handlerKey: BridgeV3.handlerKey(scope: .applicationConfiguration,
                                                 command: "conversation.search"),
                command: "conversation.search",
                scope: .applicationConfiguration,
                configurationScope: "conversations",
                serviceMethod: "FacadeConversationDomain.search",
                integrationNote: "delegates to SQLiteIntelligenceStore.search (CHA-SEARCH authority)"
            ),
            Binding(
                handlerKey: BridgeV3.handlerKey(scope: .launch,
                                                 command: "conversation.create"),
                command: "conversation.create",
                scope: .launch,
                configurationScope: nil,
                serviceMethod: "FacadeConversationDomain.create",
                integrationNote: "acceptedQueue receipt at submit (no domain ids); this reply exists only after the atomic commit; prepared{conversationID,resourceID,revision} effect carries it"
            ),
            Binding(
                handlerKey: BridgeV3.handlerKey(scope: .conversationLifecycle,
                                                 command: "conversation.get"),
                command: "conversation.get",
                scope: .conversationLifecycle,
                configurationScope: nil,
                serviceMethod: "FacadeConversationDomain.get",
                integrationNote: "owner.taskID is the real conversation id; snapshot minus live run state"
            ),
            Binding(
                handlerKey: BridgeV3.handlerKey(scope: .conversationLifecycle,
                                                 command: "conversation.rename"),
                command: "conversation.rename",
                scope: .conversationLifecycle,
                configurationScope: nil,
                serviceMethod: "FacadeConversationDomain.rename",
                integrationNote: "revision {conversation.<uuid>, floe.conversation-row.v1 digest}; one-writer CAS"
            ),
            Binding(
                handlerKey: BridgeV3.handlerKey(scope: .conversationLifecycle,
                                                 command: "conversation.archive"),
                command: "conversation.archive",
                scope: .conversationLifecycle,
                configurationScope: nil,
                serviceMethod: "FacadeConversationDomain.archive",
                integrationNote: "same CAS; NEVER touches run/fence services (ordinary archive is not a cancel)"
            ),
            Binding(
                handlerKey: BridgeV3.handlerKey(scope: .conversationLifecycle,
                                                 command: "conversation.delete"),
                command: "conversation.delete",
                scope: .conversationLifecycle,
                configurationScope: nil,
                serviceMethod: "FacadeConversationDomain.delete",
                integrationNote: "fails closed until the real RB4 ConversationDeletionLifecycle is bound"
            ),
            Binding(
                handlerKey: BridgeV3.handlerKey(scope: .conversationLifecycle,
                                                 command: "conversation.messagePage"),
                command: "conversation.messagePage",
                scope: .conversationLifecycle,
                configurationScope: nil,
                serviceMethod: "FacadeConversationDomain.messagePage",
                integrationNote: "bounded original keyset page + 48KiB frame + owned content handles"
            ),
            Binding(
                handlerKey: BridgeV3.handlerKey(scope: .conversationLifecycle,
                                                 command: "content.read"),
                command: "content.read",
                scope: .conversationLifecycle,
                configurationScope: nil,
                serviceMethod: "FacadeConversationDomain.readContent",
                integrationNote: "conversationLifecycle dual of the shared content reader"
            ),
            Binding(
                handlerKey: BridgeV3.handlerKey(scope: .applicationConfiguration,
                                                 command: "content.read"),
                command: "content.read",
                scope: .applicationConfiguration,
                configurationScope: "conversations",
                serviceMethod: "FacadeConversationDomain.readContentFromConversationsLabel",
                integrationNote: "SHARED key: binder routes by configurationScope; the live v3 matrix already carries the personalization third content.read rule under this same key - compose, never overwrite"
            ),
        ]
    }
}

// MARK: - The conversation domain service

/// Owner-side adapter over the ORIGINAL stores. One `DatabaseManager`
/// (schema 46) is injected by the trusted host; there is no second DB, no
/// RAM business fallback, and every identity comes from a real commit.
///
/// Isolation: plain Swift actor (NOT MainActor, NOT a Looper). No nested
/// store-actor await ever happens inside a DatabaseManager reader/writer
/// closure: every closure body is synchronous GRDB code, so each CAS is
/// genuinely single-writer and no nested store actor is reached mid-
/// transaction.
public actor FacadeConversationDomain {

    // MARK: Dependencies

    private let database: DatabaseManager
    private let conversationStore: SQLiteConversationStore
    private let runStore: SQLiteRunStore
    private let runningInputStore: SQLiteRunningInputStore
    private let workspaceStore: SQLiteWorkspaceStore
    private let intelligenceStore: SQLiteIntelligenceStore
    private let content: FacadeConversationContentAuthority
    private let context: ConversationFacadeContext
    /// nil until the REAL RB4 lifecycle implementation is bound.
    private let lifecycle: (any ConversationDeletionLifecycle)?
    private let credentialDrain: (any ConversationCredentialDeletionDraining)?
    private let workspaceCleaning: (any ConversationOwnedWorkspaceCleaning)?
    /// Host flow policy: bind newly created conversations to the explicit
    /// trusted default shared workspace inside the same commit transaction.
    /// Never implies "pick the first workspace" — an absent context fails
    /// closed before any write.
    private let bindsNewConversationsToDefaultWorkspace: Bool

    /// Internal, test-only seams (never reachable from a public
    /// initializer): `clock` lets concurrency tests force the same-stored-
    /// timestamp CAS case; `faultInjection` runs INSIDE the create/rename/
    /// archive commit transactions so a thrown error demonstrates a real
    /// rollback (no row, no partial write, no fake identity).
    private let clock: @Sendable () -> Date
    private let faultInjection: (@Sendable (Int) throws -> Void)?

    public init(database: DatabaseManager,
                conversationStore: SQLiteConversationStore,
                runStore: SQLiteRunStore,
                runningInputStore: SQLiteRunningInputStore,
                workspaceStore: SQLiteWorkspaceStore,
                intelligenceStore: SQLiteIntelligenceStore,
                content: FacadeConversationContentAuthority,
                context: ConversationFacadeContext,
                lifecycle: (any ConversationDeletionLifecycle)?,
                credentialDrain: (any ConversationCredentialDeletionDraining)?,
                workspaceCleaning: (any ConversationOwnedWorkspaceCleaning)?) {
        self.database = database
        self.conversationStore = conversationStore
        self.runStore = runStore
        self.runningInputStore = runningInputStore
        self.workspaceStore = workspaceStore
        self.intelligenceStore = intelligenceStore
        self.content = content
        self.context = context
        self.lifecycle = lifecycle
        self.credentialDrain = credentialDrain
        self.workspaceCleaning = workspaceCleaning
        self.bindsNewConversationsToDefaultWorkspace = false
        self.clock = { Date() }
        self.faultInjection = nil
    }

    init(database: DatabaseManager,
         conversationStore: SQLiteConversationStore,
         runStore: SQLiteRunStore,
         runningInputStore: SQLiteRunningInputStore,
         workspaceStore: SQLiteWorkspaceStore,
         intelligenceStore: SQLiteIntelligenceStore,
         content: FacadeConversationContentAuthority,
         context: ConversationFacadeContext,
         lifecycle: (any ConversationDeletionLifecycle)?,
         credentialDrain: (any ConversationCredentialDeletionDraining)?,
         workspaceCleaning: (any ConversationOwnedWorkspaceCleaning)?,
         bindsNewConversationsToDefaultWorkspace: Bool,
         clock: @escaping @Sendable () -> Date,
         faultInjection: (@Sendable (Int) throws -> Void)?) {
        self.database = database
        self.conversationStore = conversationStore
        self.runStore = runStore
        self.runningInputStore = runningInputStore
        self.workspaceStore = workspaceStore
        self.intelligenceStore = intelligenceStore
        self.content = content
        self.context = context
        self.lifecycle = lifecycle
        self.credentialDrain = credentialDrain
        self.workspaceCleaning = workspaceCleaning
        self.bindsNewConversationsToDefaultWorkspace = bindsNewConversationsToDefaultWorkspace
        self.clock = clock
        self.faultInjection = faultInjection
    }

    // MARK: Per-conversation mutation scope (synchronous, actor-isolated)

    /// Mirrors native `deletingConversationIDs` (ConversationCenter:1152)
    /// and extends the guard to the CAS admission window of every stateful
    /// metadata mutation. Set/cleared synchronously on this actor (no await
    /// between decision and insertion), so interleaved delete/rename/archive
    /// on the same conversation is deterministic:
    /// * a metadata mutation arriving while a delete is in flight is
    ///   `sessionFenced("conversationDeleting")`;
    /// * a second concurrent mutation on the same row is `duplicateInFlight`
    ///   (the mailbox additionally dedupes at correlation level);
    /// * READS (get/list/messagePage/search/archive-view list) are NOT
    ///   blocked during a drain — ordinary navigation stays live until the
    ///   commit;
    /// * late echoes/cancels cannot touch another conversation: ids are
    ///   captured values, re-checked after every await, and endScope only
    ///   ever clears OUR OWN registration.
    private var activeMutationIDs: Set<UUID> = []
    private var deletingConversationIDs: Set<UUID> = []

    private enum MutationScope { case metadata, deletion }

    private func beginScope(_ conversationID: UUID, _ kind: MutationScope) throws {
        switch kind {
        case .deletion:
            guard !deletingConversationIDs.contains(conversationID),
                  !activeMutationIDs.contains(conversationID) else {
                throw ConversationDomainError.duplicateInFlight
            }
            deletingConversationIDs.insert(conversationID)
        case .metadata:
            guard !deletingConversationIDs.contains(conversationID) else {
                throw ConversationDomainError.sessionFenced("conversationDeleting")
            }
            guard activeMutationIDs.insert(conversationID).inserted else {
                throw ConversationDomainError.duplicateInFlight
            }
        }
    }

    private func endScope(_ conversationID: UUID, _ kind: MutationScope) {
        switch kind {
        case .metadata: activeMutationIDs.remove(conversationID)
        case .deletion: deletingConversationIDs.remove(conversationID)
        }
    }

    private func isDeleting(_ conversationID: UUID) -> Bool {
        deletingConversationIDs.contains(conversationID)
    }

    // MARK: - conversation.list

    /// Bounded keyset paging over the ORIGINAL `conversations` table with
    /// the EXACT native predicate/order (ConversationStore.swift:231-233:
    /// `purpose = 'ordinary'`, optional `archived_at IS NULL`,
    /// `ORDER BY updated_at DESC, id`). The public store method returns the
    /// whole table, so this narrow mirror exists purely for bounded SQL
    /// pagination; equivalence against BOTH public forms
    /// (conversations() / conversations(includeArchived: true)) is pinned by
    /// tests on shared fixtures.
    public func list(payload: SettingsDomainV1.JSONValue?) async throws -> ConversationListReply {
        let query = try ConversationListQuery.parse(payload)
        let includeArchived = query.includeArchived
        let includeRevision = query.includeRevision

        var keyset: ConversationCursorCodec.ListPayload?
        if let cursor = query.cursor {
            guard let decoded = try ConversationCursorCodec.decodeList(cursor),
                  !decoded.updatedAt.isEmpty, !decoded.id.isEmpty,
                  ConversationWireDate.decode(decoded.updatedAt) != nil,
                  UUID(uuidString: decoded.id) != nil else {
                throw ConversationDomainError.invalidEnvelope("invalidCursor")
            }
            keyset = decoded
        }

        let database = self.database
        // Qualifier repair (2026-10-19): bind the optional to an immutable
        // shadow so the @Sendable reader closure captures a `let`, not a
        // `var` (Swift 6 #SendableClosureCaptures). No behavior change.
        let keysetForQuery: ConversationCursorCodec.ListPayload? = keyset
        struct Fetched: Sendable {
            var rows: [ConversationListRow]
            var hasMore: Bool
        }
        let fetched: Fetched = try await database.reader { db in
            var sql = """
                SELECT id, title, updated_at, archived_at
                FROM conversations
                WHERE purpose = 'ordinary'
                """
            if !includeArchived { sql += " AND archived_at IS NULL" }
            var arguments: StatementArguments = []
            if let keyset = keysetForQuery {
                // Native order (updated_at DESC, id ASC): the strict
                // successor keyset. `id` compares as the same TEXT the
                // ORDER BY uses (uuidString spelling), so no reinterpretation.
                sql += " AND (updated_at < ? OR (updated_at = ? AND id > ?))"
                arguments += [keyset.updatedAt, keyset.updatedAt, keyset.id]
            }
            sql += " ORDER BY updated_at DESC, id LIMIT ?"
            arguments += [query.limit + 1]
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            let hasMore = rows.count > query.limit
            var out: [ConversationListRow] = []
            out.reserveCapacity(min(rows.count, query.limit))
            for row in rows.prefix(query.limit) {
                guard let id = UUID(uuidString: row["id"]) else {
                    throw ConversationDomainError.persistenceUnavailable("conversationIdCorrupt")
                }
                let updated: String = row["updated_at"]
                let archived: String? = row["archived_at"]
                var revision: String?
                if includeRevision {
                    // Actual producer read inside this SAME reader
                    // transaction; no cached or recomputed-from-fields guess.
                    revision = try ConversationRowRevision.digest(db: db, conversationID: id)
                }
                out.append(ConversationListRow(
                    conversationID: id,
                    title: row["title"],
                    updatedAtRaw: updated,
                    archivedAtRaw: archived,
                    revision: revision
                ))
            }
            return Fetched(rows: out, hasMore: hasMore)
        }

        // 48 KiB serialized-page discipline with ATOMIC cursor progress:
        // trimming the oldest (tail) rows keeps every trimmed row reachable
        // through the RECOMPUTED nextCursor (it moves to the last KEPT row),
        // and hasMore stays true. The cursor never claims a complete
        // history it did not deliver.
        var rows = fetched.rows
        var hasMore = fetched.hasMore
        while Self.listPageBytes(rows: rows, nextCursor: Self.listCursor(for: rows, hasMore: hasMore),
                                 hasMore: hasMore) > SettingsDomainV1.pageBudgetBytes {
            guard rows.count > 1 else {
                // Even one row plus envelope cannot fit: defensive typed
                // refusal (the settled SDU-M3 pattern), never a partial
                // claim or a silently dropped row.
                throw ConversationDomainError.payloadTooLarge(maxBytes: SettingsDomainV1.pageBudgetBytes)
            }
            rows.removeLast()
            hasMore = true
        }
        return ConversationListReply(rows: rows,
                                     nextCursor: Self.listCursor(for: rows, hasMore: hasMore),
                                     hasMore: hasMore)
    }

    private static func listCursor(for rows: [ConversationListRow], hasMore: Bool) -> String? {
        guard hasMore, let last = rows.last else { return nil }
        return try? ConversationCursorCodec.encodeList(
            .init(updatedAt: last.updatedAtRaw, id: last.conversationID.uuidString))
    }

    private static func listPageBytes(rows: [ConversationListRow],
                                      nextCursor: String?,
                                      hasMore: Bool) -> Int {
        ConversationWireBudget.encodedObjectBytes([
            "rows": rows.map(\.wireObject),
            "nextCursor": nextCursor ?? NSNull(),
            "hasMore": hasMore,
        ])
    }

    // MARK: - conversation.search

    /// CHA-SEARCH equivalence is delegated to the ORIGINAL
    /// `SQLiteIntelligenceStore.search` (IntelligenceStore.swift:1018):
    /// FTS5 bm25 + snippet, the unicode61 CJK substring fallback, title
    /// matching, `is_searchable = 1`, `purpose = 'ordinary'`, optional
    /// workspace/date filters and the `best_rank, created_at DESC` source
    /// ordering. Archived ordinary conversations are INCLUDED because the
    /// native search SQL does not filter `archived_at` — preserving actual
    /// scope beats inventing a stricter one (the archived list view remains
    /// the `conversation.list` includeArchived predicate). No second FTS
    /// index, no new schema, no made-up semantics.
    public func search(payload: SettingsDomainV1.JSONValue?) async throws -> ConversationSearchReply {
        let query = try ConversationSearchQuery.parse(payload)
        let hits = try await intelligenceStore.search(query.request)
        var rows = hits.map { hit in
            ConversationSearchRow(
                conversationID: hit.conversationID,
                messageID: hit.messageID,
                workspaceID: hit.workspaceID,
                conversationTitle: hit.conversationTitle,
                snippet: hit.snippet,
                createdAtRaw: ConversationWireDate.encode(hit.createdAt)
            )
        }
        // The store already applied its own limit; the tail it never
        // returned cannot be measured, so truncation starts at zero and
        // only the budget trim below adds honest counts.
        var truncatedTail = 0
        while Self.searchPageBytes(rows: rows, truncatedTail: truncatedTail)
                > SettingsDomainV1.pageBudgetBytes {
            guard rows.count > 1 else {
                throw ConversationDomainError.payloadTooLarge(maxBytes: SettingsDomainV1.pageBudgetBytes)
            }
            rows.removeLast()
            truncatedTail += 1
        }
        return ConversationSearchReply(rows: rows, truncatedTailCount: truncatedTail)
    }

    private static func searchPageBytes(rows: [ConversationSearchRow],
                                        truncatedTail: Int) -> Int {
        ConversationWireBudget.encodedObjectBytes([
            "rows": rows.map(\.wireObject),
            "truncatedTail": truncatedTail,
        ])
    }

    // MARK: - conversation.get

    /// Honest snapshot projection (ConversationSessionSnapshot :704-718
    /// minus live run state). Every value comes from an ORIGINAL store or a
    /// bounded SQL read; counts are real; truncation is flagged.
    public func get(conversationID: UUID) async throws -> ConversationSessionReply {
        let record = try await ordinaryConversation(id: conversationID)

        let database = self.database
        let revision: String = try await database.reader { db in
            guard let digest = try ConversationRowRevision.digest(
                db: db, conversationID: conversationID) else {
                throw ConversationDomainError.notFound
            }
            return digest
        }

        // First-screen messages: the ORIGINAL keyset page primitive with the
        // native snapshot window (messagePage limit 20 —
        // ConversationCenter:1401-1403). Oversize rows go through the SAME
        // handle/trim projection as messagePage, so the snapshot can never
        // carry a truncated-with-completeness row either.
        let page = try await conversationStore.messagePage(
            conversationID: conversationID, before: nil, limit: 20)
        let projected = try await projectMessagePage(page: page,
                                                     conversationID: conversationID)
        let messagesTotal: Int = try await database.reader { db in
            try Int.fetchOne(db,
                             sql: "SELECT COUNT(*) FROM messages WHERE conversation_id = ?",
                             arguments: [conversationID.uuidString]) ?? 0
        }

        // Runs: the native snapshot reads recentRuns(conversationID:limit:160)
        // (:1404-1406), but the PUBLIC recentRuns default is
        // `runs(conversationID:).prefix(limit)` — fetch-all-then-claim-bounded,
        // which the admission forbids. This mirror applies the ORIGINAL runs
        // ordering (RunStore:323-325) with a real SQL LIMIT and a separate
        // COUNT for honesty; prefix-order equivalence against the public
        // API is pinned by tests on shared fixtures.
        let snapshotRunsWindow = 160 // the native snapshot window, not a new cap
        struct RunRow: Sendable, Equatable {
            let runID: UUID; let state: String
            let startedAtRaw: String; let endedAtRaw: String?
            let providerName: String?; let modelName: String?
            let conversationMode: String?
        }
        let (runRows, runsTotal): ([RunRow], Int) = try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, state, started_at, ended_at,
                       provider_name_snapshot, model_name_snapshot, conversation_mode
                FROM runs
                WHERE conversation_id = ?
                ORDER BY started_at DESC, id
                LIMIT ?
                """, arguments: [conversationID.uuidString, snapshotRunsWindow])
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM runs WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]) ?? 0
            let mapped: [RunRow] = try rows.map { row in
                guard let id = UUID(uuidString: row["id"]) else {
                    throw ConversationDomainError.persistenceUnavailable("runIdCorrupt")
                }
                return RunRow(runID: id,
                              state: row["state"],
                              startedAtRaw: row["started_at"],
                              endedAtRaw: row["ended_at"],
                              providerName: row["provider_name_snapshot"],
                              modelName: row["model_name_snapshot"],
                              conversationMode: row["conversation_mode"])
            }
            return (mapped, total)
        }
        var runSummaries = runRows.map { row in
            ConversationRunSummaryWire(runID: row.runID, state: row.state,
                                       startedAtRaw: row.startedAtRaw,
                                       endedAtRaw: row.endedAtRaw,
                                       providerName: row.providerName,
                                       modelName: row.modelName,
                                       conversationMode: row.conversationMode)
        }

        // Pending inputs: the ORIGINAL predicate/order via the public store
        // (RunningInputStore:63-71). The queue is naturally small, but the
        // projection is still budget-trimmed from the tail with an honest
        // flag; `pendingInputsTotalCount` is the REAL full-store count.
        let allPending = (try await runningInputStore.pending(conversationID: conversationID))
            .map(PendingUserInputWire.init(input:))
        let taskPolicy = try await workspaceStore.taskPolicy(conversationID: conversationID)

        var pendingWindow = allPending
        var pendingTruncated = false
        var runsTruncated = runsTotal > snapshotRunsWindow

        func build(pending: [PendingUserInputWire],
                   runs: [ConversationRunSummaryWire],
                   pendingTruncated: Bool,
                   runsTruncated: Bool) -> ConversationSessionReply {
            ConversationSessionReply(
                conversationID: record.id,
                resourceID: ConversationRowRevision.resourceID(conversationID: record.id),
                revision: revision,
                title: record.title,
                createdAtRaw: ConversationWireDate.encode(record.createdAt),
                updatedAtRaw: ConversationWireDate.encode(record.updatedAt),
                titleOrigin: record.titleOrigin.rawValue,
                archivedAtRaw: record.archivedAt.map(ConversationWireDate.encode),
                firstScreen: projected,
                messagesTotalCount: messagesTotal,
                runs: runs,
                runsTotalCount: runsTotal,
                runsTruncated: runsTruncated,
                pendingInputs: pending,
                pendingInputsTotalCount: allPending.count,
                pendingInputsTruncated: pendingTruncated,
                taskPolicy: taskPolicy
            )
        }

        var reply = build(pending: pendingWindow, runs: runSummaries,
                          pendingTruncated: pendingTruncated,
                          runsTruncated: runsTruncated)
        while ConversationWireBudget.encodedObjectBytes(reply.wireObject)
                > SettingsDomainV1.pageBudgetBytes {
            if pendingWindow.count > 1 {
                pendingWindow.removeLast()
                pendingTruncated = true
            } else if pendingWindow.count == 1 {
                pendingWindow.removeAll()
                pendingTruncated = true
            } else if runSummaries.count > 1 {
                runSummaries.removeLast()
                runsTruncated = true
            } else {
                // The immutable core (header + first screen, itself already
                // budget-checked with handles) cannot fit: defensive typed
                // refusal; nothing partial is ever returned.
                throw ConversationDomainError.payloadTooLarge(maxBytes: SettingsDomainV1.pageBudgetBytes)
            }
            reply = build(pending: pendingWindow, runs: runSummaries,
                          pendingTruncated: pendingTruncated,
                          runsTruncated: runsTruncated)
        }
        return reply
    }

    // MARK: - conversation.create

    /// Pattern mirror of ConversationCenter.createConversation (:1609-1624):
    /// real native `UUID()` minting, empty-title default, two independent
    /// `Date()` stamps like the original, `purpose: .ordinary` only, the
    /// ORIGINAL upsert statement — plus a read-back inside the SAME
    /// transaction so the committed identity and revision are real values
    /// returned ONLY after the commit. Nothing here mints a taskID/runID/
    /// environmentID for the pre-run lifecycle, and the queue receipt (owned
    /// by RB1's mailbox) never carries this identity.
    public func create(payload: SettingsDomainV1.JSONValue?) async throws -> ConversationCreateReply {
        let query = try ConversationCreateQuery.parse(payload)

        // Real workspace/project validation BEFORE any write. No automatic
        // "first workspace" selection exists in this code path at all.
        if bindsNewConversationsToDefaultWorkspace {
            guard let defaultWorkspaceID = context.defaultSharedWorkspaceID else {
                throw ConversationDomainError.runtimeUnavailable("defaultWorkspaceContextMissing")
            }
            let record = try await workspaceStore.workspace(id: defaultWorkspaceID)
            guard record != nil else {
                throw ConversationDomainError.runtimeUnavailable("trustedDefaultWorkspaceMissing")
            }
        }

        let now = clock()
        let record = ConversationRecord(
            id: UUID(),
            title: query.title ?? "",
            createdAt: now,
            updatedAt: clock(),
            purpose: .ordinary
        )
        let database = self.database
        let fault = self.faultInjection
        let bindsWorkspace = self.bindsNewConversationsToDefaultWorkspace
        let workspaceID = context.defaultSharedWorkspaceID

        struct Committed: Sendable {
            let digest: String
            let title: String
            let createdAtRaw: String
            let updatedAtRaw: String
        }
        // ONE writer transaction: INSERT (exact original upsert,
        // ConversationStore:205-219), optional workspace ownership rows
        // (exact original assignConversation statements), then read-back +
        // full-row digest. A fault inside the block rolls the ENTIRE commit
        // back — the row and any ownership link vanish together, so a failed
        // create can never leak a fake identity into a later reply.
        let committed: Committed = try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO conversations (id, title, created_at, updated_at, purpose)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        updated_at = excluded.updated_at
                    """,
                arguments: [record.id.uuidString, record.title,
                            ConversationWireDate.encode(record.createdAt),
                            ConversationWireDate.encode(record.updatedAt),
                            record.purpose.rawValue]
            )
            if bindsWorkspace, let workspaceID {
                try Self.assignOwnershipStatements(db: db,
                                                   workspaceID: workspaceID,
                                                   conversationID: record.id)
            }
            try fault?(1)
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversations WHERE id = ?",
                arguments: [record.id.uuidString]
            ) else {
                throw ConversationDomainError.persistenceUnavailable("createReadbackMissing")
            }
            guard (row["purpose"] as String) == ConversationPurpose.ordinary.rawValue else {
                // Defense in depth: an ordinary-only API cannot return a
                // notes-owned row.
                throw ConversationDomainError.persistenceUnavailable("createPurposeDrift")
            }
            let digest = ConversationRowRevision.digest(of: row)
            let createdRaw: String = row["created_at"]
            let updatedRaw: String = row["updated_at"]
            let title: String = row["title"]
            return Committed(digest: digest, title: title,
                             createdAtRaw: createdRaw, updatedAtRaw: updatedRaw)
        }

        return ConversationCreateReply(
            conversationID: record.id,
            resourceID: ConversationRowRevision.resourceID(conversationID: record.id),
            revision: committed.digest,
            title: committed.title,
            createdAtRaw: committed.createdAtRaw,
            updatedAtRaw: committed.updatedAtRaw
        )
    }

    /// Exact statement copy of the ORIGINAL assignment path:
    /// SQLiteWorkspaceStore.assignConversation (WorkspaceStore.swift:371-398
    /// — workspace EXISTS guard + canonical one-to-one ownership UPSERT)
    /// followed by the linkConversation compatibility projection
    /// (:224-243 — workspace_conversations INSERT ... DO NOTHING). Run
    /// inside the create transaction; provenance-pinned by an equivalence
    /// test against the two public store methods on shared fixtures.
    private static func assignOwnershipStatements(db: Database,
                                                  workspaceID: UUID,
                                                  conversationID: UUID) throws {
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM workspaces WHERE id = ?)",
            arguments: [workspaceID.uuidString]
        ) == true else {
            throw ConversationDomainError.runtimeUnavailable("trustedDefaultWorkspaceMissing")
        }
        try db.execute(
            sql: """
                INSERT INTO conversation_workspace_ownership
                    (conversation_id, workspace_id, assigned_at)
                VALUES (?, ?, ?)
                ON CONFLICT(conversation_id) DO UPDATE SET
                    workspace_id = excluded.workspace_id,
                    assigned_at = excluded.assigned_at
                WHERE conversation_workspace_ownership.workspace_id <> excluded.workspace_id
                """,
            arguments: [conversationID.uuidString, workspaceID.uuidString,
                        ConversationWireDate.encode(Date())]
        )
        try db.execute(
            sql: """
                INSERT INTO workspace_conversations
                    (workspace_id, conversation_id, created_at)
                VALUES (?, ?, ?)
                ON CONFLICT(workspace_id, conversation_id) DO NOTHING
                """,
            arguments: [workspaceID.uuidString,
                        conversationID.uuidString,
                        ConversationWireDate.encode(Date())]
        )
    }

    // MARK: - conversation.rename (CAS)

    /// ONE original writer transaction: full-row digest compare, then the
    /// EXACT original rename UPDATE
    /// (`UPDATE conversations SET title = ?, title_origin = 'manual',
    /// updated_at = ? WHERE id = ?` — ConversationStore.swift:252), then the
    /// read-back digest. Native semantics preserved: title_origin becomes
    /// 'manual', updated_at becomes the write-time codec value;
    /// created_at/purpose are untouched. The CAS token is the canonical
    /// `floe.conversation-row.v1` digest, NOT updated_at — a
    /// same-clock/same-stored-timestamp edit with a different title is
    /// stale, never a false overwrite (RB3 revisionClarification).
    public func rename(conversationID: UUID,
                       revision: BaseRevision,
                       payload: SettingsDomainV1.JSONValue?) async throws -> ConversationMutationReply {
        let query = try ConversationRenameQuery.parse(payload)
        try Self.requireRevisionShape(revision, conversationID: conversationID)
        try beginScope(conversationID, .metadata)
        defer { endScope(conversationID, .metadata) }

        let database = self.database
        let fault = self.faultInjection
        let clock = self.clock
        let newDigest: String = try await database.writer { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversations WHERE id = ?",
                arguments: [conversationID.uuidString]
            ) else { throw ConversationDomainError.notFound }
            guard (row["purpose"] as String) == ConversationPurpose.ordinary.rawValue else {
                throw ConversationDomainError.notFound
            }
            let current = ConversationRowRevision.digest(of: row)
            guard current == revision.version else {
                throw ConversationDomainError.staleRevision
            }
            try db.execute(
                sql: "UPDATE conversations SET title = ?, title_origin = 'manual', updated_at = ? WHERE id = ?",
                arguments: [query.title, ConversationWireDate.encode(clock()),
                            conversationID.uuidString]
            )
            try fault?(2)
            guard db.changesCount > 0 else {
                throw ConversationDomainError.staleRevision
            }
            guard let after = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversations WHERE id = ?",
                arguments: [conversationID.uuidString]
            ) else {
                throw ConversationDomainError.persistenceUnavailable("renameReadbackMissing")
            }
            return ConversationRowRevision.digest(of: after)
        }
        return ConversationMutationReply(conversationID: conversationID,
                                         resourceID: revision.resourceID,
                                         revision: newDigest)
    }

    // MARK: - conversation.archive (CAS)

    /// Same single-writer CAS as rename, applying the EXACT original
    /// setArchived statement (`UPDATE conversations SET archived_at = ?,
    /// updated_at = ? WHERE id = ?` — ConversationStore.swift:381-387):
    /// archive stamps the write-time codec value, unarchive stores NULL.
    /// Archive is ORDINARY navigation metadata only: this path never calls
    /// the lifecycle port and never cancels anything (an ordinary run keeps
    /// running under its service owner — admission rule).
    public func archive(conversationID: UUID,
                        revision: BaseRevision,
                        payload: SettingsDomainV1.JSONValue?) async throws -> ConversationMutationReply {
        let query = try ConversationArchiveQuery.parse(payload)
        try Self.requireRevisionShape(revision, conversationID: conversationID)
        try beginScope(conversationID, .metadata)
        defer { endScope(conversationID, .metadata) }

        let database = self.database
        let clock = self.clock
        let newDigest: String = try await database.writer { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversations WHERE id = ?",
                arguments: [conversationID.uuidString]
            ) else { throw ConversationDomainError.notFound }
            guard (row["purpose"] as String) == ConversationPurpose.ordinary.rawValue else {
                throw ConversationDomainError.notFound
            }
            let current = ConversationRowRevision.digest(of: row)
            guard current == revision.version else {
                throw ConversationDomainError.staleRevision
            }
            try db.execute(
                sql: "UPDATE conversations SET archived_at = ?, updated_at = ? WHERE id = ?",
                arguments: [query.archived ? ConversationWireDate.encode(clock()) : nil,
                            ConversationWireDate.encode(clock()),
                            conversationID.uuidString]
            )
            guard db.changesCount > 0 else {
                throw ConversationDomainError.staleRevision
            }
            guard let after = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversations WHERE id = ?",
                arguments: [conversationID.uuidString]
            ) else {
                throw ConversationDomainError.persistenceUnavailable("archiveReadbackMissing")
            }
            return ConversationRowRevision.digest(of: after)
        }
        return ConversationMutationReply(conversationID: conversationID,
                                         resourceID: revision.resourceID,
                                         revision: newDigest)
    }

    // MARK: - conversation.delete

    /// Native deletion ORDERING (ConversationCenter.deleteConversation
    /// :5938-5979 + stopRunsAndDelete :6106-6176), fail-closed and now with
    /// the three Main-review corrections (CH-R1..CH-R3):
    ///
    /// revision shape + lifecycle bound → admission CAS (real reader) →
    /// owned-workspace capture → operation-owned fence begin (exact
    /// conversation/epoch/operation token) → real per-conversation drain +
    /// target-token evidence gate (unrelated B is never counted/cancelled)
    /// → exact `RuntimeOwnedWorkRegistry.isAttached` re-check → ONE
    /// original-store writer transaction: expected-row/purpose CAS +
    /// original memory preservation + RunLifecycleRetention + DELETE + FK
    /// cascades + V11/V36 triggers, spool purge only after commit → exact
    /// fence commit → bounded workspace-file/vault drains (durable queues
    /// make any deferral process-death recoverable) → content-handle
    /// release for THIS conversation only. Every non-commit exit aborts the
    /// exact fence token.
    ///
    /// CH-R1: the expected raw-row/purpose CAS and the ORIGINAL delete run
    /// in the SAME `DatabaseManager.writer` transaction. A separate
    /// preflight no longer authorizes the destruction; an external writer
    /// that mutates the row after admission is observed by the in-writer
    /// CAS and the transaction refuses before memory preservation or any
    /// destructive write. Legitimate final owned-run writes during the drain
    /// may advance `updated_at` only (`appendMessage`,
    /// ConversationStore.swift:412-416); every other raw column must still
    /// equal the admission snapshot and `updated_at` may never move
    /// backwards.
    ///
    /// There is no timer release of outstanding I/O: the drain either truly
    /// completed or the operation failed closed. Notes rows/tables and
    /// temporary storage are outside this path by authority (purpose check
    /// at admission AND again inside the same deletion writer).
    public func delete(conversationID: UUID,
                       revision: BaseRevision) async throws -> ConversationDeleteReply {
        try Self.requireRevisionShape(revision, conversationID: conversationID)
        guard let lifecycle = self.lifecycle else {
            // Fail closed: no direct SQLite-only delete while owned
            // producers (launch transactions, run services, children)
            // may still be writing. The row is untouched.
            throw ConversationDomainError.runtimeUnavailable("conversationDeletionLifecycleUnregistered")
        }

        try beginScope(conversationID, .deletion)
        var scopeSettled = false
        defer {
            if !scopeSettled { endScope(conversationID, .deletion) }
        }
        // A caller cancellation observed BEFORE any authority work is
        // honoured immediately (rows intact; no fence has been registered).
        try Task.checkCancellation()

        struct Admission: Sendable {
            let digest: String
            let title: String
            let purpose: String
            let immutableFields: [String: SettingsDomainV1.CanonicalDigest.Field]
            let updatedAtRaw: String

            var expectation: ConversationDeleteExpectation {
                ConversationDeleteExpectation(purpose: purpose,
                                             immutableFields: immutableFields,
                                             updatedAtRaw: updatedAtRaw)
            }
        }
        let database = self.database
        let admission: Admission = try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversations WHERE id = ?",
                arguments: [conversationID.uuidString]
            ) else { throw ConversationDomainError.notFound }
            let purpose: String = row["purpose"]
            guard purpose == ConversationPurpose.ordinary.rawValue else {
                throw ConversationDomainError.notFound
            }
            let digest = ConversationRowRevision.digest(of: row)
            guard digest == revision.version else {
                throw ConversationDomainError.staleRevision
            }
            // Typed ORIGINAL fetches for the values the flow needs (a
            // DatabaseValue is NOT `as? String`-castable; GRDB decodes via
            // the column subscript, same as the store's own mapper).
            let updated: String = row["updated_at"]
            let title: String = row["title"]
            var immutable: [String: SettingsDomainV1.CanonicalDigest.Field] = [:]
            for (name, value) in row where name != "updated_at" {
                immutable[name] = ConversationRowRevision.field(value)
            }
            return Admission(digest: digest, title: title, purpose: purpose,
                             immutableFields: immutable, updatedAtRaw: updated)
        }

        // Owned workspace captured BEFORE the drain (native order :5949-5954).
        let ownedWorkspaceID = try await workspaceStore.workspaceID(conversationID: conversationID)
        var capturedPrivateTask: (workspaceID: UUID, relativePath: String)?
        if let ownedWorkspaceID,
           let record = try await workspaceStore.workspace(id: ownedWorkspaceID),
           record.kind == .privateTask,
           let relative = record.internalRelativePath {
            capturedPrivateTask = (ownedWorkspaceID, relative)
        }

        // CH-R3: operation-owned fence. `beginDeletionFence` is atomic: it
        // either returns a registered guard for THIS exact operation identity
        // or throws with no guard registered. It atomically invalidates the
        // per-conversation launch epoch and refuses when another live
        // operation already holds the guard.
        let hostEpoch = context.hostEpoch
        let operationID = UUID()
        let fence: ConversationDeletionFence
        do {
            fence = try await lifecycle.beginDeletionFence(
                conversationID: conversationID, epoch: hostEpoch,
                operationID: operationID)
        } catch let failure as ConversationDeletionLifecycleFailure {
            throw Self.mapLifecycleFailure(failure)
        } catch is CancellationError {
            // Begin is atomic: a cancelled begin must not have registered a
            // guard. Preserve cancellation rather than misreporting a fence.
            throw CancellationError()
        } catch {
            throw ConversationDomainError.runtimeUnavailable("deletionFenceUnavailable")
        }
        // Exact token validation: the authority must return OUR operation's
        // fence for THIS conversation/epoch. A foreign operation's fence is
        // never settled here (no old/foreign abort can clear a newer guard).
        guard fence.conversationID == conversationID,
              fence.epoch == hostEpoch else {
            throw ConversationDomainError.sessionFenced("deletionFenceIdentityMismatch")
        }
        guard fence.operationID == operationID else {
            throw ConversationDomainError.sessionFenced("deletionFenceOperationMismatch")
        }
        guard !fence.authorityReceipt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            _ = await lifecycle.abortDeletionFence(fence)
            throw ConversationDomainError.sessionFenced("deletionFenceReceiptMissing")
        }

        var committed = false
        do {
            // Real per-conversation quiescence. No timeout, no timer release,
            // and caller cancellation is checked below (a cancelled drain is
            // NOT quiescence). The adapter must keep target owned work
            // attached until its REAL completion/final writes.
            // Qualifier repair (2026-10-19): the drain is a typed lifecycle
            // port too; its failures map onto the SAME frozen wire vocabulary
            // as begin (a raw adapter failure must never escape the facade).
            let quiescence: ConversationQuiescenceReport
            do {
                quiescence = try await lifecycle.drainOwnedWork(fence: fence)
            } catch let failure as ConversationDeletionLifecycleFailure {
                throw Self.mapLifecycleFailure(failure)
            }

            try Task.checkCancellation()
            guard isDeleting(conversationID) else {
                throw ConversationDomainError.sessionFenced("deletionScopeLost")
            }
            guard quiescence.conversationID == conversationID else {
                throw ConversationDomainError.sessionFenced("quiescenceConversationMismatch")
            }
            guard quiescence.launchesFenced else {
                throw ConversationDomainError.runtimeUnavailable("launchesNotFenced")
            }
            // CH-R2 gate: exact TARGET-conversation evidence + explicit
            // pending-launch count. Global epoch counts are diagnostic only;
            // an unrelated conversation B may legitimately be active and must
            // neither block nor be cancelled by deleting A.
            if let refusal = quiescence.refusalReason(conversationID: conversationID,
                                                      expectedEpoch: hostEpoch) {
                throw Self.mapQuiescenceRefusal(refusal)
            }

            try Task.checkCancellation()

            // CH-R1: the SAME writer transaction performs the expected
            // raw-row/purpose CAS, the original memory reclassification, and
            // the original RunLifecycleRetention/DELETE/cascades/triggers.
            // A stale row refuses before any write (including memory), so a
            // failed delete cannot touch Notes or another owner's memories.
            let expectation = admission.expectation
            try await conversationStore.deleteConversation(
                id: conversationID,
                expectedRow: { row in try expectation.verify(row) },
                beforeDelete: { db in
                    try ConversationDeletionMemoryPreservation.preserve(
                        db: db, conversationID: conversationID,
                        ownerLabel: admission.title)
                })
            committed = true

            // CH-R3: exact-token commit AFTER the durable commit. The DB
            // row is the source of truth; a failed guard release is reported
            // honestly and remains recoverable, never a second deletion.
            let fenceSettlement = await lifecycle.commitDeletionFence(fence)

            // Post-commit bounded cleanups, honest about deferral.
            // Cancellation from here on cannot un-delete; every status below
            // stays truthful and the durable queues are recoverable.
            var cleanupStatus: ConversationDeleteCleanupStatus = .none
            if let captured = capturedPrivateTask {
                cleanupStatus = await cleanupOwnedPrivateWorkspace(captured)
            }

            var credentialStatus: ConversationCredentialDrainStatus = .deferredUnbound
            if let credentialDrain = self.credentialDrain {
                credentialStatus = .drained(await credentialDrain.drainDeletionQueue())
            }

            // Release staged content handles for the deleted conversation
            // AFTER the commit; handles of OTHER conversations are never
            // touched (the authority index filters by conversationID).
            let released = await content.release(forConversationID: conversationID)

            scopeSettled = true
            endScope(conversationID, .deletion)

            return ConversationDeleteReply(conversationID: conversationID,
                                           quiescence: quiescence,
                                           workspaceCleanup: cleanupStatus,
                                           credentialDrain: credentialStatus,
                                           contentHandlesReleased: released,
                                           fenceSettlement: fenceSettlement)
        } catch {
            // CH-R3: every pre-commit exit (throw, cancellation, stale,
            // drain failure, expected-row CAS refusal) settles the EXACT
            // operation fence. This releases only OUR guard; owned-work
            // tokens are never detached here, so the surviving conversation
            // can relaunch only after its real remaining work settles.
            if !committed {
                _ = await lifecycle.abortDeletionFence(fence)
            }
            throw error
        }
    }

    /// Epoch/scope fencing failures use `sessionFenced`; missing or
    /// non-drained owned-work evidence stays `runtimeUnavailable`.
    private static func mapQuiescenceRefusal(_ reason: String) -> ConversationDomainError {
        switch reason {
        case "quiescenceEpochMismatch", "ownedWorkForeignEpoch":
            return .sessionFenced(reason)
        default:
            return .runtimeUnavailable(reason)
        }
    }

    /// Maps the typed lifecycle failures onto the frozen wire vocabulary.
    /// Adapter-supplied reasons stay bounded opaque tokens (never row
    /// content, paths or secrets).
    private static func mapLifecycleFailure(_ failure: ConversationDeletionLifecycleFailure)
        -> ConversationDomainError
    {
        switch failure {
        case .epochMismatch:
            return .sessionFenced("deletionFenceEpochMismatch")
        case .fenceHeld:
            return .duplicateInFlight
        case .conversationNotFound:
            return .notFound
        case .fenceTokenRefused:
            return .sessionFenced("deletionFenceTokenRefused")
        case .ownerUnavailable(let reason):
            return .runtimeUnavailable("deletionOwnerUnavailable:\(reason)")
        case .drainUnavailable(let reason):
            return .runtimeUnavailable("deletionDrainUnavailable:\(reason)")
        case .reportUnavailable(let reason):
            return .runtimeUnavailable("deletionReportUnavailable:\(reason)")
        }
    }

    private func cleanupOwnedPrivateWorkspace(_ captured: (workspaceID: UUID, relativePath: String)) async
        -> ConversationDeleteCleanupStatus
    {
        guard let cleaning = self.workspaceCleaning else {
            return .deferredQueueRetained("workspaceCleaningUnbound")
        }
        do {
            // Native ownership re-check (retryPendingLocalCleanup
            // WorkspaceCenter:386-396): no surviving conversation may share
            // the workspace.
            let survivors = try await workspaceStore.conversations(workspaceID: captured.workspaceID)
            guard survivors.isEmpty else {
                return .deferredQueueRetained("workspaceOwnershipSurvivors")
            }
            if let record = try await workspaceStore.workspace(id: captured.workspaceID) {
                guard record.kind == .privateTask,
                      record.internalRelativePath == captured.relativePath else {
                    return .deferredQueueRetained("workspaceOwnershipChanged")
                }
                // ORIGINAL row removal; the V36 workspace trigger re-queues
                // via INSERT OR IGNORE over the existing cleanup row — safe.
                try await workspaceStore.deleteWorkspace(id: captured.workspaceID)
            }
            try await cleaning.removePrivateTaskDirectory(relativePath: captured.relativePath)
            try await workspaceStore.finishLocalCleanup(workspaceID: captured.workspaceID)
            return .removed
        } catch let error as ConversationDomainError {
            return .failed(error.wireCode)
        } catch {
            // The durable cleanup row REMAINS; the next launch sweep (or an
            // explicit retryPendingLocalWorkspaceCleanup) completes
            // recovery. Process-death recoverable by construction.
            return .failed("cleanupThrew")
        }
    }

    /// Bootstrap/launch retry mirror of
    /// WorkspaceCenter.retryPendingLocalCleanup (:380-408) over the
    /// ORIGINAL store APIs. Returns a typed per-workspace failure map;
    /// uncleaned rows simply stay queued. No-op when no host file port is
    /// bound (deferral remains recoverable).
    public func retryPendingLocalWorkspaceCleanup() async -> [String: String] {
        var failures: [String: String] = [:]
        guard let cleaning = self.workspaceCleaning else { return failures }
        do {
            let pending = try await workspaceStore.pendingLocalCleanup()
            for item in pending {
                do {
                    let survivors = try await workspaceStore.conversations(workspaceID: item.workspaceID)
                    guard survivors.isEmpty else { continue }
                    if let record = try await workspaceStore.workspace(id: item.workspaceID) {
                        guard record.kind == .privateTask,
                              record.internalRelativePath == item.relativePath else {
                            throw ConversationDomainError.sessionFenced("cleanupOwnershipChanged")
                        }
                        try await workspaceStore.deleteWorkspace(id: item.workspaceID)
                    }
                    try await cleaning.removePrivateTaskDirectory(relativePath: item.relativePath)
                    try await workspaceStore.finishLocalCleanup(workspaceID: item.workspaceID)
                } catch {
                    failures[item.workspaceID.uuidString] = "cleanupFailed"
                }
            }
        } catch {
            failures["_query"] = "cleanupQueueUnavailable"
        }
        return failures
    }

    // MARK: - conversation.messagePage

    /// The ORIGINAL bounded keyset page (ConversationStore.swift:481-534:
    /// `before` = strict (created_at,id) less-than, DESC fetch + reverse,
    /// `hasEarlier` from the real extra row) reused directly — the service
    /// map pins it as "built-in paging primitive for the 64KiB frame
    /// contract". On top of it: the 48 KiB serialized-page discipline with
    /// ATOMIC progress — trimming the oldest rows advances the earlier
    /// cursor to the oldest KEPT row (trimmed content stays reachable), and
    /// an oversized single row keeps ALL its bytes in an owned content
    /// handle instead of a truncated inline.
    public func messagePage(conversationID: UUID,
                            payload: SettingsDomainV1.JSONValue?) async throws
        -> ConversationMessagePageReply
    {
        _ = try await ordinaryConversation(id: conversationID)
        let query = try ConversationMessagePageQuery.parse(payload,
                                                            decodeCursor: Self.decodeMessageCursor)
        let page = try await conversationStore.messagePage(
            conversationID: conversationID, before: query.cursor, limit: query.limit)
        return try await projectMessagePage(page: page, conversationID: conversationID)
    }

    /// The store's own cursor primitive: the createdAt string the store
    /// binds at :494 is exactly `PersistenceCodec.encode(cursor.createdAt)`
    /// (this codec mirror), so carrying that string through an opaque
    /// cursor cannot shift the keyset; the UUID tie-breaker is compared as
    /// TEXT like the store's `id < ?`.
    static func decodeMessageCursor(_ raw: String) throws -> ConversationMessageCursor? {
        guard let decoded = try ConversationCursorCodec.decodeMessage(raw) else { return nil }
        guard !decoded.createdAt.isEmpty, !decoded.id.isEmpty,
              let messageID = UUID(uuidString: decoded.id),
              let createdAt = ConversationWireDate.decode(decoded.createdAt) else {
            throw ConversationDomainError.invalidEnvelope("invalidCursor")
        }
        return ConversationMessageCursor(createdAt: createdAt, messageID: messageID)
    }

    static func encodeMessageCursor(_ cursor: ConversationMessageCursor) throws -> String {
        try ConversationCursorCodec.encodeMessage(.init(
            createdAt: ConversationWireDate.encode(cursor.createdAt),
            id: cursor.messageID.uuidString))
    }

    /// Turns one store page into a budget-true page:
    /// 1. Every row whose FULL inline content would not fit the 48 KiB page
    ///    by itself (decision via the P0 `shouldInline` helper against the
    ///    row's real encoded shape) is staged through the shared bounded
    ///    reader and bound to its durable message (owned handle path).
    /// 2. The whole page is measured; if it still overflows, the OLDEST
    ///    rows are removed (their staged bytes released) until it fits,
    ///    and the cursor/canary flags are recomputed so the trimmed rows
    ///    remain reachable.
    /// 3. If even a single fully-handled row cannot fit, staged bytes for
    ///    the attempt are released and the page fails closed
    ///    (`payloadTooLarge`). Truncation with a completeness label is
    ///    structurally impossible in this builder.
    private func projectMessagePage(page: ConversationMessagePage,
                                    conversationID: UUID) async throws
        -> ConversationMessagePageReply
    {
        var staged: [UUID: (handle: String, totalBytes: Int)] = [:]
        func releaseStaged() async {
            for entry in staged.values {
                await content.release(handle: entry.handle)
            }
            staged.removeAll(keepingCapacity: false)
        }

        for message in page.messages
        where ConversationMessageReplyBuilder.requiresHandle(message: message) {
            guard let result = await content.publish(conversationID: conversationID,
                                                     messageID: message.id,
                                                     text: message.content) else {
                // The shared reader declined (saturated / row vanished):
                // nothing is truncated to squeeze past it.
                await releaseStaged()
                throw ConversationDomainError.runtimeUnavailable("contentReaderSaturated")
            }
            staged[message.id] = result
        }

        var working = page.messages
        var trimmedAny = false
        while true {
            // ATOMIC cursor progress (documented rule): when rows were
            // trimmed, the continued cursor is the OLDEST KEPT row and
            // hasEarlier is forced — trimmed rows are strictly older and
            // stay reachable through it. Without a kept row the store's own
            // canary passes through unchanged.
            var reencodedCursor: String?
            if trimmedAny {
                guard let earliest = working.first else {
                    await releaseStaged()
                    throw ConversationDomainError.persistenceUnavailable("cursorRowEmpty")
                }
                reencodedCursor = try? Self.encodeMessageCursor(
                    ConversationMessageCursor(createdAt: earliest.createdAt,
                                              messageID: earliest.id))
            }
            let reply = ConversationMessageReplyBuilder.build(
                messages: working,
                staged: staged,
                originalPage: page,
                reencodedEarlierCursor: reencodedCursor,
                forceHasEarlier: trimmedAny)
            let bytes = ConversationWireBudget.encodedObjectBytes(reply.wireObject)
            if bytes <= SettingsDomainV1.pageBudgetBytes {
                return reply
            }
            guard working.count > 1 else {
                await releaseStaged()
                throw ConversationDomainError.payloadTooLarge(maxBytes: SettingsDomainV1.pageBudgetBytes)
            }
            let dropped = working.removeFirst()
            if let entry = staged.removeValue(forKey: dropped.id) {
                await content.release(handle: entry.handle)
            }
            trimmedAny = true
        }
    }

    // MARK: - content.read (the two existing scopes)

    /// conversationLifecycle `content.read`: owner-bound. The handle must
    /// be bound to THIS conversation, the current host generation, and the
    /// bound row must still be readable in this store. Foreign conversation,
    /// expired generation, unknown handle → typed notFound; offset rules are
    /// enforced by the shared reader (scalar boundaries) and surfaced as
    /// invalidEnvelope("contentOffsetInvalid").
    public func readContent(conversationID: UUID,
                            payload: SettingsDomainV1.JSONValue?) async throws
        -> ConversationContentSliceReply
    {
        let request = try ConversationContentReadRequest.parse(payload)
        _ = try await ordinaryConversation(id: conversationID)
        return try await content.read(conversationID: conversationID, request: request)
    }

    /// applicationConfiguration `content.read` with label `conversations`.
    /// No owner exists in this scope, so authority is re-derived from the
    /// handle's REAL bound conversation. The future personalization lane
    /// adds its own label branch under the SAME handler key — the binder
    /// must COMPOSE this method by configurationScope and never replace it.
    public func readContentFromConversationsLabel(configurationScope: String?,
                                                  payload: SettingsDomainV1.JSONValue?) async throws
        -> ConversationContentSliceReply
    {
        guard configurationScope == "conversations" else {
            // Not this lane's label: fail closed instead of serving another
            // domain's handle.
            throw ConversationDomainError.invalidEnvelope("configurationScopeMismatch")
        }
        let request = try ConversationContentReadRequest.parse(payload)
        return try await content.readWithinOrdinaryConversation(request: request)
    }

    // MARK: - Shared helpers

    private func ordinaryConversation(id: UUID) async throws -> ConversationRecord {
        guard let record = try await conversationStore.conversation(id: id) else {
            throw ConversationDomainError.notFound
        }
        guard record.purpose == .ordinary else {
            // Notes-owned rows are foreign to this domain. Absent and
            // foreign are indistinguishable on the wire (typed notFound), so
            // the ordinary API never leaks another workspace's existence.
            throw ConversationDomainError.notFound
        }
        return record
    }

    static func requireRevisionShape(_ revision: BaseRevision,
                                     conversationID: UUID) throws {
        guard !revision.version.isEmpty else {
            throw ConversationDomainError.invalidEnvelope("invalidRevision")
        }
        guard ConversationRowRevision.matches(revisionResourceID: revision.resourceID,
                                              conversationID: conversationID) else {
            // The revision must name the SAME conversation as the owner
            // role — the parsed-UUID comparison precedent from the frozen
            // v3 cursor rule. Never a silent re-pair.
            throw ConversationDomainError.invalidEnvelope("revisionResourceMismatch")
        }
    }
}
