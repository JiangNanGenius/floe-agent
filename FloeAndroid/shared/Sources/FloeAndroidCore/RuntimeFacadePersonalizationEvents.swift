// SPDX-License-Identifier: MPL-2.0
//
// P8 — G02 runtime event handoff: real event-driven personalization
// cadence (private source candidate; UNCOMPILED).
// Job job-676ec714cb334606 (RB3b intelligence backend lane).
//
// Authority: contract runtimeIntegrationHandoff (FINITE G02 HANDOFF),
// commandTable entry 19 policyBoundary, ownership.runtimeEventOwnership,
// asyncAndLifetime.runtimeEventTasks, behavioralTestDesign P8 vectors
// (runtime.events* + negativeTests events.*),
// IMPLEMENTATION_HANDOFF.md P8-runtime-events.
//
// PROVENANCE (behavior references only — FloeApp/ConversationCenter is NOT
// imported; no SwiftUI/CloudKit/FloeSync/MemoryDreamService anywhere):
// * FloeAgent/FloeApp/Remote/ConversationCenter.swift:5524-5572
//   recordPersonalizationActivity: temporary conversations return BEFORE any
//   counter change (isTemporaryConversation :1628-1630); it calls the
//   ORIGINAL PersonalizationService.recordActivity and then generateIfDue
//   for BOTH kinds when a general-auxiliary generator exists.
// * ConversationCenter.swift:3755-3780 + :3885 (ordinary user-message
//   activity at commit; conversationID passed so the temporary guard
//   applies), :5386-5402 (completed-run activity ONLY for
//   terminalState == "completed" with a success outcome, runSurface ==
//   .ordinary and !isTemporaryRun; failed/cancelled runs never count).
// * Personalization.swift:594-622 generateIfDue cadence (7d / 10 runs /
//   30 messages, :88-110), :624-637 recordActivity, :706-717 resetCursor,
//   :719-730 substantial-change → INACTIVE automatic draft (the same
//   CAS/draft pipeline as P4, never a second path).
// * MemoryDreamService is FloeApp-only/do-not-copy: the shared runtime has
//   NO automatic candidate producer, so this package provides the FENCED
//   projection hook for a future real producer and invents NO candidate
//   rows, NO timers, NO scheduler, NO durable event log, NO second
//   generation path (boundaries: G11 owns OS timers only).
//
// EVENT FEED BOUNDARY (explicit, not a gap in this package): the actual
// persisted ordinary user-message commit truth and completed+successful
// ordinary-run truth are owned by the RB4 runs/approvals lane
// (job-f6772d4de1584403: SQLiteRunLaunchStore.prepare real atomic
// conversation/workspace/run/userMessage commit + ConversationRunService
// terminal lifecycle). This file implements the REAL handler; Main/RB4
// attach the feed by constructing the typed events below at their commit
// callbacks. No synthetic timer, no replay-invented counter, no fabricated
// "feed attached" status: until the real feed calls these entries, no
// cadence advances — automatic hook READY is never claimed here.
//
// Delivery semantics (runtimeIntegrationHandoff.replayFence):
// at-most-once in-process AFTER the persisted commit; in-process exactly-
// once dedupe keyed by the REAL message/run id (bounded defensive set —
// not a persistent second ledger); no historical replay after restart; a
// late callback after End/Delete/Clear is dropped and can never write into
// a reused/new conversation identity; workspace ownership is read from the
// real ownership row at event time, never from shared UI state. Temporary-
// at-start / temporary-at-commit / temporary-at-handling, deleted
// conversation, and history-clear fences are checked on EVERY path. The
// handler never blocks the commit path, never keeps mailbox active-slot
// accounting alive, and a projection teardown never cancels the underlying
// ordinary run.

import Foundation
import GRDB
import FloeCore
import FloePersistence
import FloeAgentRuntime

// MARK: - Typed persisted-event identities (RB4 feed inputs)

/// One feed-owned OPERATION LEASE identity (MEM-P8-LIFETIME). The REAL RB4
/// feed acquires the root+per-conversation owned operation lease atomically
/// against its current drain/delete/history-clear/temporary admission BEFORE
/// invoking this processor, holds it through the processor's DB/model
/// terminal, and maps this EXACT token into a same-conversation delete drain
/// (a different conversation is never blocked). This type only names that
/// truth on the wire-internal event; it is NOT a wire command, NOT a
/// permission and NOT durable state. This source deliberately does NOT mint
/// the lease: acquisition and the delete-drain mapping belong to the real
/// RB4 feed owner, so a method here can never fake an owned lease.
public struct PersonalizationEventOperationLease: Sendable, Equatable {
    /// Opaque feed-owned token (never a path, secret or wire identity).
    public let token: String
    public let conversationID: UUID
    public let rootEpoch: UInt64

    public init(token: String, conversationID: UUID, rootEpoch: UInt64) {
        self.token = token
        self.conversationID = conversationID
        self.rootEpoch = rootEpoch
    }
}

/// Validation seam supplied by the TRUSTED RB4 feed owner. The processor
/// asks it whether the EXACT lease delivered with an event is still admitted
/// (no drain, delete, history clear or temporary flip for that conversation)
/// immediately before the first DB/model mutation. When an event carries a
/// lease, a missing validator fails CLOSED (an unverifiable lifetime claim is
/// never trusted); when no event carries a lease, this source keeps its
/// fence-only behavior and claims NO owned-lease guarantee — the complete
/// feed binding remains the later RB4/App gate.
public protocol PersonalizationEventOwnedLeaseProviding: Sendable {
    func isEventOperationLeaseValid(_ lease: PersonalizationEventOperationLease) async -> Bool
}

/// One PERSISTED ordinary user message at its commit callback. All fields
/// are the RB4 owner's real captured truth; the handler RE-VERIFIES the
/// durable rows from the original DB and never trusts the event alone.
public struct PersonalizationOrdinaryUserMessageEvent: Sendable, Equatable {
    public let messageID: UUID
    public let conversationID: UUID
    /// The trusted launch/root owner epoch captured at commit (RB1 root).
    public let rootEpoch: UInt64
    /// Temporary-at-start / temporary-at-commit flags as frozen by the run
    /// owner at creation/commit (never recomputed from mutable UI state).
    public let temporaryAtStart: Bool
    public let temporaryAtCommit: Bool
    /// The feed's held owned-operation lease (MEM-P8-LIFETIME). nil means
    /// the caller does not provide one: the handler then keeps fence-only
    /// checks and claims no feed attachment.
    public let operationLease: PersonalizationEventOperationLease?

    public init(messageID: UUID, conversationID: UUID, rootEpoch: UInt64,
                temporaryAtStart: Bool, temporaryAtCommit: Bool,
                operationLease: PersonalizationEventOperationLease? = nil) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.rootEpoch = rootEpoch
        self.temporaryAtStart = temporaryAtStart
        self.temporaryAtCommit = temporaryAtCommit
        self.operationLease = operationLease
    }
}

/// One run transitioned to state='completed' with ended_at committed AND a
/// success outcome on the ordinary surface. Failed/cancelled or
/// non-ordinary/special-surface runs must never be delivered here; the
/// handler still re-checks the durable row + the trusted flags.
public struct PersonalizationOrdinaryRunCompletedEvent: Sendable, Equatable {
    public let runID: UUID
    public let conversationID: UUID
    public let rootEpoch: UInt64
    public let temporaryAtStart: Bool
    /// The run owner's frozen temporary authority at terminal time
    /// ("frozen temporary run" fence).
    public let frozenTemporaryRun: Bool
    /// The run owner's surface truth (ordinary only). The conversation
    /// purpose is re-verified against the original DB regardless.
    public let ordinarySurface: Bool
    public let succeeded: Bool
    /// Optional feed-held owned-operation lease (see
    /// PersonalizationEventOperationLease).
    public let operationLease: PersonalizationEventOperationLease?

    public init(runID: UUID, conversationID: UUID, rootEpoch: UInt64,
                temporaryAtStart: Bool, frozenTemporaryRun: Bool,
                ordinarySurface: Bool, succeeded: Bool,
                operationLease: PersonalizationEventOperationLease? = nil) {
        self.runID = runID
        self.conversationID = conversationID
        self.rootEpoch = rootEpoch
        self.temporaryAtStart = temporaryAtStart
        self.frozenTemporaryRun = frozenTemporaryRun
        self.ordinarySurface = ordinarySurface
        self.succeeded = succeeded
        self.operationLease = operationLease
    }
}

/// Candidate lifecycle activity (reachable ONLY through the real
/// MemoryCandidatePipeline persistence path, i.e. a future G02 producer;
/// the current overlay registers no producer, so nothing here invents
/// candidate rows). Uses the same ownership/temporary fence and NEVER
/// changes cadence counters (native policy).
public struct PersonalizationCandidateActivityEvent: Sendable, Equatable {
    public let candidateID: UUID
    /// Conversation/workspace ownership captured at run START.
    public let conversationID: UUID?
    public let workspaceID: UUID?
    public let rootEpoch: UInt64
    public let temporaryAtStart: Bool
    /// Optional feed-held owned-operation lease (conversation-scoped).
    public let operationLease: PersonalizationEventOperationLease?

    public init(candidateID: UUID, conversationID: UUID?, workspaceID: UUID?,
                rootEpoch: UInt64, temporaryAtStart: Bool,
                operationLease: PersonalizationEventOperationLease? = nil) {
        self.candidateID = candidateID
        self.conversationID = conversationID
        self.workspaceID = workspaceID
        self.rootEpoch = rootEpoch
        self.temporaryAtStart = temporaryAtStart
        self.operationLease = operationLease
    }
}

// MARK: - Trusted fence port (RB1 root/epoch owner + RB4 lifecycle)

/// The trusted launch/root/owner fences. The RB1 root owner supplies the
/// epoch, temporary-conversation registry and delete/clear fencing; this
/// handler consults it at HANDLING time in addition to the event's frozen
/// start/commit truth — a late old-owner callback can never touch a new
/// root or a reused conversation identity.
public protocol PersonalizationEventFenceProviding: Sendable {
    func currentRootEpoch() async -> UInt64
    func isTemporaryConversation(_ conversationID: UUID) async -> Bool
    func isDeletionOrHistoryClearPending(_ conversationID: UUID) async -> Bool
}

// MARK: - Dispositions

public enum PersonalizationEventDropReason: String, Sendable, Equatable {
    case temporaryAtStart
    case temporaryAtCommit
    case temporaryAtHandling
    case frozenTemporaryRun
    case failedOrNonSuccessRun
    case nonOrdinarySurface
    case staleRootOwnerEpoch
    case deletedOrFencedConversation
    case sourceRowInvalid
}

/// Honest per-event outcome for host tests and feed logging. NOTHING here
/// is a wire command; the Settings domain is not involved.
public enum PersonalizationEventDisposition: Sendable, Equatable {
    /// Counter advanced by the original recordActivity + cadence evaluated.
    case counted(dedupeKey: String, workspaceID: UUID?,
                 cadenceDue: [String: Bool])
    /// Cadence not due (or route unavailable): counters persisted, no
    /// generation attempted — NEVER a fabricated document/candidate.
    case countedCadenceNotDue(dedupeKey: String, workspaceID: UUID?)
    /// Automatic generation pass result (P4 CAS/draft pipeline).
    case countedWithAutomaticGeneration(dedupeKey: String, workspaceID: UUID?,
                                        outcomes: [String: FacadePersonalizationGenerate.AutomaticOutcome])
    case duplicate(dedupeKey: String)
    case dropped(reason: PersonalizationEventDropReason)
    case candidateProjectionRefreshed(candidateID: UUID, pendingCount: Int)
    case failed(reason: String)
}

// MARK: - Bounded in-process dedupe ledger

/// Defensive in-process duplicate suppression keyed by the REAL message/run
/// id with the contract's exact dedupe key strings. This is NOT a durable
/// event log (nothing is persisted; restart never replays) — the persisted
/// rows themselves plus this bounded set give at-most-once delivery.
internal final class FacadeEventDedupeLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<String> = []
    private var order: [String] = []
    /// Bounded defensive set (process-lifetime). 4096 keys ≈ one app
    /// instance's worth of counted activity; eviction only re-enables the
    /// theoretical double-count of a DUPLICATE re-delivery of a very old
    /// id (never of a fresh event) — documented, not invented semantics.
    static let maximumKeys = 4096

    /// Atomically reserves a key. Returns false when it was already
    /// delivered in this process.
    func reserve(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !seen.contains(key) else { return false }
        seen.insert(key)
        order.append(key)
        while order.count > Self.maximumKeys {
            let oldest = order.removeFirst()
            seen.remove(oldest)
        }
        return true
    }
}

// MARK: - The event processor

/// Concrete P8 event processor: consumed EXACTLY per
/// runtimeIntegrationHandoff. Real persisted ordinary user messages and
/// completed successful ordinary runs ONLY; authoritative original-DB
/// validity/readback plus trusted launch/root/owner fences. recordActivity
/// uses the ORIGINAL PersonalizationService actor (outside any
/// transaction); the cadence evaluation uses the ORIGINAL
/// PersonalizationUpdateCadence over the persisted cursor; the generation
/// pass is the SAME P4 CAS/draft pipeline (one model request per pass,
/// active only while slot+source are unchanged and the change is not
/// substantial, otherwise exactly one INACTIVE draft). The candidate event
/// is a fenced bounded projection refresh over the real memory_candidates
/// rows — it never changes cadence counters and never creates rows.
public actor FacadePersonalizationEvents {
    public static func messageDedupeKey(_ messageID: UUID) -> String {
        "personalization.activity.msg.\(messageID.uuidString)"
    }

    public static func runDedupeKey(_ runID: UUID) -> String {
        "personalization.activity.run.\(runID.uuidString)"
    }

    public static func candidateDedupeKey(_ candidateID: UUID,
                                          status: String) -> String {
        "personalization.candidate.\(candidateID.uuidString).\(status)"
    }

    private let database: DatabaseManager
    private let personalizationService: PersonalizationService
    private let generate: FacadePersonalizationGenerate
    private let memoryAdapter: FacadeMemoryAdapter
    private let cadence: PersonalizationUpdateCadence
    private let fences: any PersonalizationEventFenceProviding
    private let ownedLeases: (any PersonalizationEventOwnedLeaseProviding)?
    private let dedupe = FacadeEventDedupeLedger()

    public init(database: DatabaseManager,
                personalizationService: PersonalizationService,
                generate: FacadePersonalizationGenerate,
                memoryAdapter: FacadeMemoryAdapter,
                cadence: PersonalizationUpdateCadence = PersonalizationUpdateCadence(),
                fences: any PersonalizationEventFenceProviding,
                ownedLeases: (any PersonalizationEventOwnedLeaseProviding)? = nil) {
        self.database = database
        self.personalizationService = personalizationService
        self.generate = generate
        self.memoryAdapter = memoryAdapter
        self.cadence = cadence
        self.fences = fences
        self.ownedLeases = ownedLeases
    }

    /// MEM-P8-LIFETIME composition point. The REAL RB4 feed acquires the
    /// owned lease BEFORE calling a handler and holds it through the
    /// handler's DB/model terminal; this check happens immediately before
    /// the first mutation and fails CLOSED if the exact lease is no longer
    /// admitted. Without a delivered lease there is no owned-lease claim at
    /// all (fence-only handling, unchanged) — this source never mints a
    /// lease, a root epoch or a drain token.
    private func leaseDropReason(_ lease: PersonalizationEventOperationLease,
                                 conversationID: UUID,
                                 rootEpoch: UInt64) async
        -> PersonalizationEventDropReason?
    {
        guard lease.conversationID == conversationID else {
            return .deletedOrFencedConversation
        }
        guard lease.rootEpoch == rootEpoch else { return .staleRootOwnerEpoch }
        guard let ownedLeases else {
            // A lease that no trusted owner can validate proves nothing:
            // never treat the mere presence of a token as a lifetime fence.
            return .deletedOrFencedConversation
        }
        guard await ownedLeases.isEventOperationLeaseValid(lease) else {
            return .deletedOrFencedConversation
        }
        return nil
    }

    // MARK: - persisted ordinary user message

    public func handleOrdinaryUserMessage(_ event: PersonalizationOrdinaryUserMessageEvent,
                                          now: Date = Date()) async
        -> PersonalizationEventDisposition
    {
        let key = Self.messageDedupeKey(event.messageID)
        // Creation-time fences (temporary-at-start/commit never count).
        if event.temporaryAtStart {
            return .dropped(reason: .temporaryAtStart)
        }
        if event.temporaryAtCommit {
            return .dropped(reason: .temporaryAtCommit)
        }
        // Handling-time root-owner fence: a late old-owner callback can
        // never write into the current/new root.
        if await fences.currentRootEpoch() != event.rootEpoch {
            return .dropped(reason: .staleRootOwnerEpoch)
        }
        // Authoritative original-DB validity/readback: the message row must
        // REALLY be a persisted user message of the claimed conversation,
        // and the conversation must REALLY exist with purpose='ordinary'
        // (row gone = deleted; anything but ordinary never counts). The
        // workspace ownership is read from the REAL ownership row at event
        // time — never from shared mutable UI state.
        let verification: ConversationTruth
        do {
            verification = try await verifyOrdinaryConversation(
                conversationID: event.conversationID,
                messageAssertion: .userMessage(event.messageID))
        } catch {
            return .failed(reason: "persistenceUnavailable")
        }
        switch verification.status {
        case .invalid:
            return .dropped(reason: .sourceRowInvalid)
        case .valid:
            break
        }
        if await fences.isTemporaryConversation(event.conversationID) {
            return .dropped(reason: .temporaryAtHandling)
        }
        if await fences.isDeletionOrHistoryClearPending(event.conversationID) {
            return .dropped(reason: .deletedOrFencedConversation)
        }
        if let lease = event.operationLease,
           let reason = await leaseDropReason(lease,
                                              conversationID: event.conversationID,
                                              rootEpoch: event.rootEpoch) {
            return .dropped(reason: reason)
        }
        guard dedupe.reserve(key) else {
            return .duplicate(dedupeKey: key)
        }
        // ORIGINAL actor path — recordActivity outside any transaction.
        do {
            try await personalizationService.recordActivity(
                completedRuns: 0, userMessages: 1,
                workspaceID: verification.workspaceID, now: now)
        } catch {
            return .failed(reason: "persistenceUnavailable")
        }
        return await evaluateCadence(workspaceID: verification.workspaceID,
                                     dedupeKey: key, now: now)
    }

    // MARK: - completed successful ordinary run

    public func handleOrdinaryRunCompleted(_ event: PersonalizationOrdinaryRunCompletedEvent,
                                           now: Date = Date()) async
        -> PersonalizationEventDisposition
    {
        let key = Self.runDedupeKey(event.runID)
        if event.temporaryAtStart {
            return .dropped(reason: .temporaryAtStart)
        }
        if event.frozenTemporaryRun {
            return .dropped(reason: .frozenTemporaryRun)
        }
        if !event.ordinarySurface {
            return .dropped(reason: .nonOrdinarySurface)
        }
        if !event.succeeded {
            return .dropped(reason: .failedOrNonSuccessRun)
        }
        if await fences.currentRootEpoch() != event.rootEpoch {
            return .dropped(reason: .staleRootOwnerEpoch)
        }
        let verification: ConversationTruth
        do {
            verification = try await verifyOrdinaryConversation(
                conversationID: event.conversationID,
                messageAssertion: .completedRun(event.runID))
        } catch {
            return .failed(reason: "persistenceUnavailable")
        }
        switch verification.status {
        case .invalid:
            return .dropped(reason: .sourceRowInvalid)
        case .valid:
            break
        }
        if await fences.isTemporaryConversation(event.conversationID) {
            return .dropped(reason: .temporaryAtHandling)
        }
        if await fences.isDeletionOrHistoryClearPending(event.conversationID) {
            return .dropped(reason: .deletedOrFencedConversation)
        }
        if let lease = event.operationLease,
           let reason = await leaseDropReason(lease,
                                              conversationID: event.conversationID,
                                              rootEpoch: event.rootEpoch) {
            return .dropped(reason: reason)
        }
        guard dedupe.reserve(key) else {
            return .duplicate(dedupeKey: key)
        }
        do {
            try await personalizationService.recordActivity(
                completedRuns: 1, userMessages: 0,
                workspaceID: verification.workspaceID, now: now)
        } catch {
            return .failed(reason: "persistenceUnavailable")
        }
        return await evaluateCadence(workspaceID: verification.workspaceID,
                                     dedupeKey: key, now: now)
    }

    // MARK: - candidate activity (future real producer only)

    /// Fenced projection refresh over the REAL memory_candidates rows:
    /// bounded candidatesPage (the P2 mutating-read adapter, incl. its
    /// honest expiry sweep), NO counter change, NO row invention.
    /// Temporary/deleted conversations are fenced at creation AND at
    /// handling exactly like the counted events.
    public func handleCandidateActivity(_ event: PersonalizationCandidateActivityEvent,
                                        status: DurableMemoryCandidateStatus) async
        -> PersonalizationEventDisposition
    {
        let key = Self.candidateDedupeKey(event.candidateID, status: status.rawValue)
        if event.temporaryAtStart {
            return .dropped(reason: .temporaryAtStart)
        }
        if await fences.currentRootEpoch() != event.rootEpoch {
            return .dropped(reason: .staleRootOwnerEpoch)
        }
        if let conversationID = event.conversationID {
            let verification: ConversationTruth
            do {
                verification = try await verifyOrdinaryConversation(
                    conversationID: conversationID, messageAssertion: .none)
            } catch {
                return .failed(reason: "persistenceUnavailable")
            }
            switch verification.status {
            case .invalid:
                return .dropped(reason: .sourceRowInvalid)
            case .valid:
                break
            }
            if await fences.isTemporaryConversation(conversationID) {
                return .dropped(reason: .temporaryAtHandling)
            }
            if await fences.isDeletionOrHistoryClearPending(conversationID) {
                return .dropped(reason: .deletedOrFencedConversation)
            }
        }
        if let lease = event.operationLease {
            guard let conversationID = event.conversationID else {
                // A conversation-scoped lease delivered without its
                // conversation can never be validated: fail closed.
                return .dropped(reason: .deletedOrFencedConversation)
            }
            if let reason = await leaseDropReason(lease,
                                                  conversationID: conversationID,
                                                  rootEpoch: event.rootEpoch) {
                return .dropped(reason: reason)
            }
        }
        guard dedupe.reserve(key) else {
            return .duplicate(dedupeKey: key)
        }
        // The candidate row must be REAL (produced through the actual
        // pipeline); the refresh reads only bounded projection state.
        do {
            let page = try await memoryAdapter.candidatesPage(
                MemoryCandidatesListRequest(status: .pending, cursor: 0, limit: 50))
            return .candidateProjectionRefreshed(candidateID: event.candidateID,
                                                 pendingCount: page.candidates.count)
        } catch {
            return .failed(reason: "persistenceUnavailable")
        }
    }

    // MARK: - internals

    private struct ConversationTruth: Sendable {
        enum Status: Sendable { case valid, invalid }
        let status: Status
        let workspaceID: UUID?
    }

    private enum MessageAssertion: Sendable {
        case none
        case userMessage(UUID)
        case completedRun(UUID)
    }

    /// ONE original-DB reader transaction: the persisted rows are the
    /// authority (never the event alone).
    private func verifyOrdinaryConversation(conversationID: UUID,
                                            messageAssertion: MessageAssertion) async throws
        -> ConversationTruth
    {
        let database = self.database
        return try await database.reader { db in
            guard let conversation = try Row.fetchOne(db, sql: """
                SELECT purpose FROM conversations WHERE id = ?
                """, arguments: [conversationID.uuidString]) else {
                return ConversationTruth(status: .invalid, workspaceID: nil)
            }
            let purpose: String = conversation["purpose"]
            guard purpose == "ordinary" else {
                return ConversationTruth(status: .invalid, workspaceID: nil)
            }
            switch messageAssertion {
            case .none:
                break
            case .userMessage(let messageID):
                guard let message = try Row.fetchOne(db, sql: """
                    SELECT conversation_id, role FROM messages WHERE id = ?
                    """, arguments: [messageID.uuidString]) else {
                    return ConversationTruth(status: .invalid, workspaceID: nil)
                }
                let owner: String = message["conversation_id"]
                let role: String = message["role"]
                guard owner == conversationID.uuidString, role == "user" else {
                    return ConversationTruth(status: .invalid, workspaceID: nil)
                }
            case .completedRun(let runID):
                guard let run = try Row.fetchOne(db, sql: """
                    SELECT conversation_id, state, ended_at FROM runs WHERE id = ?
                    """, arguments: [runID.uuidString]) else {
                    return ConversationTruth(status: .invalid, workspaceID: nil)
                }
                let owner: String = run["conversation_id"]
                let state: String = run["state"]
                let endedAt: String? = run["ended_at"]
                guard owner == conversationID.uuidString, state == "completed",
                      endedAt != nil else {
                    return ConversationTruth(status: .invalid, workspaceID: nil)
                }
            }
            // Real ownership row at event time (the original
            // workspaceIDs helper's MIN(workspace_id) pattern).
            let ownership = try Row.fetchOne(db, sql: """
                SELECT MIN(workspace_id) AS workspace_id
                FROM conversation_workspace_ownership
                WHERE conversation_id = ?
                """, arguments: [conversationID.uuidString])
            let workspace: String? = ownership.map { ($0["workspace_id"] as String?) ?? nil } ?? nil
            return ConversationTruth(status: .valid,
                                     workspaceID: workspace.flatMap(UUID.init(uuidString:)))
        }
    }

    /// Original cadence rule over the PERSISTED cursor, then the SAME
    /// P4 CAS/draft automatic pipeline for both kinds — exactly the native
    /// hook shape (recordActivity, then generateIfDue per kind when a
    /// general-auxiliary generator exists; no generator → honest skip,
    /// counters stay persisted). Never a second generation path, never a
    /// durable queue, never a timer.
    private func evaluateCadence(workspaceID: UUID?,
                                 dedupeKey: String,
                                 now: Date) async -> PersonalizationEventDisposition
    {
        let database = self.database
        var dueByKind: [String: Bool] = [:]
        var generationOutcomes: [String: FacadePersonalizationGenerate.AutomaticOutcome] = [:]
        do {
            for kind in PersonalizationDocumentKind.allCases {
                let kindRaw = kind.rawValue
                // One read-only snapshot of the PERSISTED cursor; the
                // ORIGINAL cadence rule is evaluated on the returned
                // values (no mutation inside the DB closure).
                let state: (persisted: Bool, due: Bool) = try await database.reader { db in
                    let workspaceKey = workspaceID?.uuidString ?? ""
                    guard let row = try Row.fetchOne(db, sql: """
                        SELECT automatic_updates_enabled, last_generated_at,
                               completed_runs_since_update, user_messages_since_update
                        FROM personalization_update_cursors
                        WHERE kind = ? AND workspace_key = ?
                        """, arguments: [kindRaw, workspaceKey]) else {
                        // The ORIGINAL store synthesizes the default cursor
                        // WITHOUT persisting it (:386-391): enabled=true,
                        // counters 0 → never due.
                        return (persisted: false, due: false)
                    }
                    let enabledValue: DatabaseValue = row["automatic_updates_enabled"]
                    var enabled = true
                    if case .int64(let raw) = enabledValue.storage { enabled = raw != 0 }
                    let lastText: String? = row["last_generated_at"]
                    let runsValue: DatabaseValue = row["completed_runs_since_update"]
                    let messagesValue: DatabaseValue = row["user_messages_since_update"]
                    var runs = 0
                    var messages = 0
                    if case .int64(let raw) = runsValue.storage { runs = Int(raw) }
                    if case .int64(let raw) = messagesValue.storage { messages = Int(raw) }
                    let synthesized = PersonalizationUpdateCursor(
                        kind: kind,
                        workspaceID: workspaceID,
                        automaticUpdatesEnabled: enabled,
                        lastGeneratedAt: lastText.flatMap(FacadeStoreTime.parse),
                        completedRunsSinceUpdate: runs,
                        userMessagesSinceUpdate: messages,
                        updatedAt: now)
                    return (persisted: true, due: cadence.isDue(synthesized, now: now))
                }
                dueByKind[kindRaw] = state.due
                if state.due,
                   let wireKind = SettingsDomainV1.PersonalizationKind(rawValue: kindRaw) {
                    let outcome = try await generate.automaticGenerate(
                        kind: wireKind, workspaceID: workspaceID, now: now)
                    if let outcome {
                        generationOutcomes[kindRaw] = outcome
                    }
                }
            }
        } catch {
            return .failed(reason: "persistenceUnavailable")
        }
        if generationOutcomes.isEmpty {
            let anyDue = dueByKind.values.contains(true)
            if anyDue {
                // Due but the pass skipped (latch busy / route unavailable):
                // honest no-generation reporting.
                return .countedWithAutomaticGeneration(dedupeKey: dedupeKey,
                                                      workspaceID: workspaceID,
                                                      outcomes: generationOutcomes)
            }
            return .countedCadenceNotDue(dedupeKey: dedupeKey,
                                         workspaceID: workspaceID)
        }
        return .countedWithAutomaticGeneration(dedupeKey: dedupeKey,
                                               workspaceID: workspaceID,
                                               outcomes: generationOutcomes)
    }
}
