// SPDX-License-Identifier: MPL-2.0
//
// G02 temporary session (RB5 successor, actual-qualification revision) —
// shared vocabulary, session authority types, the owner-controlled
// commit-boundary fence, the synchronous navigation gate, the immutable
// temporary store bundle and the typed integration ports.
//
// This file supersedes the source-only RB5 candidate
// (runtime-temporary-session-source, job-21ee86c6798b4e20) and carries the
// two mandatory Main repairs:
//
//   * TMP-COMMIT-1 — discard versus the ACTUAL SQLite COMMIT is linearized
//     at the real commit callback: a `PromotionCommitBoundaryObserver`
//     registered on the SAME writer connection lets GRDB invoke
//     `databaseWillCommit()` from SQLite's sqlite3_commit_hook DURING the
//     COMMIT statement; the fence's authoritative `beginFinalCommit`
//     consultation happens THERE, and a flip that landed after the writer
//     closure returned but before COMMIT still rolls the whole transaction
//     back (ZERO durable rows). `finishFinalCommit` resolves only after the
//     writer await really committed or really threw. In-body checks are
//     advisory only.
//   * TMP-NAV-2 — `TemporaryNavigationGate` is the synchronous admission
//     domain: `temp.end` flips the session tombstone + commit fence inside
//     the binder submit path (lock-only, no await, no I/O, no SQLite)
//     BEFORE the receipt returns, and the typed `value.navigationFence`
//     admission acknowledgement rides the SAME reviewed RB1 effect pump as
//     a NON-terminal `prepared` stage carrying the exact object. Actual
//     store close, run cancellation and drain follow asynchronously
//     through the real owned services. Queued/`prepared`-without-fence/
//     refusal answers are NEVER an acknowledgement; exact alreadyAbsent /
//     alreadyRetired certifications are produced under the SAME lock and
//     are therefore authoritative.
//
// Ownership (unchanged RB5 contract + runtime-facade-contract lines 28-29,
// 91-94, 108, 158; BRIDGE_V3_MAIN_DECISIONS.json; reviewed RB1 archive):
// * ONE service-owned temporary session per accepted generation epoch —
//   never view/Activity-owned. Rotation, background/inactive, lock and view
//   reconstruction PRESERVE the exact session, run and route; an actual
//   navigation or New Task issues `temp.end` BEFORE the next route's
//   commands; process death restores nothing.
// * Identities are minted by the Swift domain owner and become AUTHORITATIVE
//   only after the RAM session commits — never at queue acceptance. The
//   queue receipt carries correlationID + operationReceiptID only.
// * RAM-only state uses the ORIGINAL Ephemeral* stores. No parallel store,
//   no second database, no ordinary SQLite write while temporary, no durable
//   draft/checkpoint/log/notification/sync side effects. `close()` plus the
//   tombstone make late appends fail closed.
// * The public-web/text-only ceiling is the ORIGINAL canonical
//   TemporaryChatToolPolicy (publicWebToolNames; provider-backed search
//   removed when unconfigured — D1 closure). The runtime executor
//   re-validates EVERY main and delegated child call via
//   `Configuration.temporaryReadOnly`; the canonical runtime
//   tools.list/tools.search pseudo schemas stay the original
//   presentation-only surface over the temporary-filtered descriptors
//   (MAIN_TEMPORARY_DISCOVERY_PRESENTATION_DECISION_20261020) — this lane
//   never widens the executable allowlist and never trusts descriptors
//   alone.
// * The Keep durable commit is the ORIGINAL ConversationPromoter over the
//   SAME schema-46 owner `DatabaseManager`, in ONE writer transaction.
// * Temporary memory/personalization feeds are excluded at start, commit
//   and handler; the committed Keep receipt carries the frozen
//   temporaryAtStart / frozenTemporaryRun truth (no retroactive learning).
//
// Android-owned regular file (this package). Imports exactly the shared
// modules already on the FloeAndroidCore target; nothing here writes the
// upstream FloeAgent tree.
import Foundation
import FloeCore
import FloePersistence

// MARK: - Typed temporary-domain error vocabulary

/// Closed, content-free typed classification for every temporary refusal.
/// Wire settlement reuses the EXISTING mailbox effect kinds and the
/// existing `RuntimeFacadeCode` values; refusals ride the frozen
/// `wireError` carrier shape (errorCode + reason inside the typed value).
public struct TemporaryDomainError: Error, Sendable, Equatable {
    public enum Code: String, Sendable, CaseIterable {
        case notFound                   // no live session / wrong hosted id
        case staleRevision              // incarnation CAS mismatch
        case duplicateInFlight          // a Keep is already running
        case invalidState               // illegal for the session state
        case sessionDiscarded           // navigation tombstone (authoritative)
        case persistenceUnavailable     // original store threw (typed)
        case needsConfiguration         // run port / availability unbound
        case capabilityUnavailable      // ceiling route cannot be composed
        case payloadTooLarge            // decoded payload over domain bound
        case internalError              // invariant broken (classified)
    }
    public enum Reason: String, Sendable, CaseIterable {
        case sessionAbsent, sessionNotCurrent, anotherSessionActive,
             incarnationMismatch
        case resourceIDMismatch, revisionAbsent
        case keepAlreadyInFlight, keepNotCommitted, tailForwardPending
        case tombstonedDiscarded, promotionRefusedByFence
        case storeWriteFailed, storeReadFailed, promoterCommitFailed
        case runDomainUnbound, webSearchAvailabilityUnbound, modelRouteUnresolved
        case ceilingEmpty, attachmentsUnavailableInTemporary
        case goalModeUnsupportedStore, stagingHandlesUnavailable
        case payloadInvalid, payloadTooLarge
        case generationRetired, epochFenced
        case `internal`
    }
    public let code: Code
    public let reason: Reason

    public init(_ code: Code, _ reason: Reason) {
        self.code = code
        self.reason = reason
    }

    /// Wire object: {"error": <code raw>, "reason": <reason raw>} — the
    /// settled detail map (identity/vocabulary only, never content).
    public var wireObject: [String: String] {
        ["error": code.rawValue, "reason": reason.rawValue]
    }
}

// MARK: - Domain reply (settlement projection)

/// One temporary command outcome. Accepted terminals carry their typed
/// result through the frozen F7 OBJECT value carrier (never JSON-as-
/// detail-string), exactly like every other qualified G02 domain: the App
/// reads `conversationID` / `incarnation` / `rootEpoch` / `keep` from the
/// terminal VALUE. `mutationAccepted` identifiers stay opaque — never raw
/// content, never a path, never a secret.
public struct TemporaryDomainReply: Sendable {
    public enum Outcome: Sendable {
        case mutationAccepted(detail: [String: String], value: DesignJSONValue)
        case rejected(TemporaryDomainError)
    }
    public let outcome: Outcome
    public init(_ outcome: Outcome) { self.outcome = outcome }

    public var acceptedValueObject: [String: DesignJSONValue]? {
        if case .mutationAccepted(_, let value) = outcome,
           case .object(let pairs) = value { return pairs }
        return nil
    }

    public func commandResult() -> RuntimeCommandResult {
        switch outcome {
        case .mutationAccepted(let detail, let value):
            return RuntimeCommandResult(kind: .accepted, detail: detail,
                                         value: value)
        case .rejected(let error):
            // EXACT frozen RB4 convention (`RunDomainReply.terminalResult`):
            // typed wire code + reason ride the existing `detail` map; no
            // new labels, no content, never a fabricated success.
            switch error.code {
            case .persistenceUnavailable:
                return RuntimeCommandResult(kind: .failed, code: .storeOpenFailed,
                                            detail: error.wireObject)
            default:
                return RuntimeCommandResult(kind: .rejected,
                                            code: .ordinaryRuntimeBlocked,
                                            detail: error.wireObject)
            }
        }
    }
}

// MARK: - Session revision authority

/// The contract revision spelling for a LIVE temporary session:
/// `session.<conversationID>` / `<incarnation>` (frozen temp rules —
/// "revisions: sourced from original stores/session incarnation"). Values
/// are opaque identities — never trimmed, never re-spelled.
public enum TemporarySessionRevision {
    public static func resourceID(conversationID: UUID) -> String {
        "session.\(conversationID.uuidString)"
    }
    public static func version(incarnation: UUID) -> String {
        incarnation.uuidString
    }
}

// MARK: - Owner-controlled commit-boundary fence (TMP-COMMIT-1)

/// The authoritative commit-boundary fence for ONE temporary Keep,
/// implementing the promoter mirror's `PromotionCommitFence`. Consultations
/// are synchronous and lock-only (safe inside the GRDB writer and inside
/// SQLite's commit callback, and on any binder/JNI thread). `flip()` is
/// performed synchronously by end/retirement BEFORE any await — which is
/// what makes the tombstone authoritative rather than advisory.
///
/// Linearization contract (honest boundaries):
/// * flip lands BEFORE the real pre-COMMIT callback (`databaseWillCommit`):
///   `beginFinalCommit()` returns false THERE and the COMMIT is converted to
///   a rollback — the whole transaction lands ZERO durable rows, even if the
///   writer closure already returned;
/// * flip lands AFTER the callback allowed the commit (the in-flight fsync
///   window): the commit won the real boundary; the recorded outcome is the
///   truth the writer resolves to (`finishFinalCommit(committed:)`);
/// * flip after resolution — idempotent; the recorded truth stands.
/// A Keep whose commit genuinely completed is, and stays, an ordinary saved
/// chat ("only genuinely committed durable rows survive"); every refusal
/// path is the opposite: ZERO durable rows.
public final class TemporaryPromotionCommitFence: PromotionCommitFence,
                                                  @unchecked Sendable {
    public enum CommitPhase: Sendable, Equatable {
        case open
        case attemptStarted
        case resolved(committed: Bool)
    }
    /// What the flip observed at the linearization instant.
    public enum FlipResolution: Sendable, Equatable {
        case refusesUpcomingCommit
        case commitInProgress
        case commitWon
        case commitLost
    }

    private let lock = NSLock()
    private var fenced = false
    private var phase: CommitPhase = .open
    private var refusedAtCommitBoundary = false
    /// The exact session identity this fence belongs to; carried so a
    /// mis-wired call can be classified `internal`, never silently accepted.
    public let sessionConversationID: UUID
    public let sessionIncarnation: UUID

    public init(sessionConversationID: UUID, sessionIncarnation: UUID) {
        self.sessionConversationID = sessionConversationID
        self.sessionIncarnation = sessionIncarnation
    }

    /// Synchronous authoritative discard. Called by end/retirement BEFORE
    /// any await. Idempotent; returns what the flip observed.
    @discardableResult
    public func flip() -> FlipResolution {
        lock.lock(); defer { lock.unlock() }
        fenced = true
        switch phase {
        case .open: return .refusesUpcomingCommit
        case .attemptStarted: return .commitInProgress
        case .resolved(let committed): return committed ? .commitWon : .commitLost
        }
    }

    /// Early inside-transaction consultation (body start). A THROWN-flip
    /// discard refuses; an already-committed attempt does NOT block the
    /// domain's idempotent tail-resume (the durable rows are truth and the
    /// resume writes only the missing tail through the same gateways).
    public func allowsCommit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !fenced
    }

    /// AUTHORITATIVE consultation, made by the promoter's commit-boundary
    /// observer inside SQLite's commit callback (GRDB
    /// `databaseWillCommit`). False converts the COMMIT into a rollback:
    /// zero durable rows. True registers the commit as in flight from this
    /// real pre-COMMIT instant (the only true commit-winner window).
    public func beginFinalCommit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        // One attempt at a time; a discard REFUSES the COMMIT. A previous
        // resolved attempt (committed tail-resume or a rolled-back retry)
        // may be followed by a new attempt while the session is not fenced.
        guard phase != .attemptStarted, !fenced else {
            refusedAtCommitBoundary = true
            return false
        }
        phase = .attemptStarted
        return true
    }

    /// True when the real pre-COMMIT callback had to refuse (the promoter
    /// normalizes that SQLite abort into `PromotionCommitRefused`).
    public var commitBoundaryRefused: Bool {
        lock.lock(); defer { lock.unlock() }
        return refusedAtCommitBoundary
    }

    /// Resolves a registered attempt to the writer's REAL outcome. A no-op
    /// when no attempt is in flight (e.g. an early refusal or a validation
    /// throw before the final guard). Never fabricates an outcome.
    public func finishFinalCommit(committed: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard phase == .attemptStarted else { return }
        phase = .resolved(committed: committed)
    }

    public var isFlipped: Bool {
        lock.lock(); defer { lock.unlock() }
        return fenced
    }

    /// The recorded commit truth (nil while unresolved).
    public var commitPhase: CommitPhase {
        lock.lock(); defer { lock.unlock() }
        return phase
    }
}

// MARK: - Synchronous navigation gate (TMP-NAV-2)

/// The authoritative outcome of one synchronous `temp.end` admission,
/// decided under the gate lock BEFORE any await, mailbox or store touch.
public enum TemporaryEndAdmission: Sendable, Equatable {
    case fenced(conversationID: UUID, incarnation: UUID)
    case alreadyRetired(conversationID: UUID, incarnation: UUID)
    case alreadyAbsent(conversationID: UUID)
    case refused(TemporaryDomainError)

    public var admittedReason: String? {
        switch self {
        case .fenced: return "fenced"
        case .alreadyRetired: return "alreadyRetired"
        case .alreadyAbsent: return "alreadyAbsent"
        case .refused: return nil
        }
    }
    public var isAdmitted: Bool { admittedReason != nil }
    /// Only a first actual fence of a LIVE session requires the async
    /// cleanup (store close + explicit run cancels); retired/absent
    /// certifications perform no second cleanup.
    public var requiresCleanup: Bool {
        if case .fenced = self { return true }
        return false
    }
}

/// The typed navigation-fence admission acknowledgement (closed keys —
/// the exact frozen App contract consumed from `value.navigationFence`;
/// never inside a `page`, never with a new label). The epoch is the ACTUAL
/// trusted native root generation (MAIN_TEMP_ACK_NATIVE_EPOCH_DECISION).
public struct TemporaryNavigationFenceAck: Sendable {
    public let conversationID: UUID
    public let incarnationID: UUID
    public let requestCorrelationID: String
    public let epoch: UInt64
    public let reason: String

    public func valueObject() -> DesignJSONValue {
        .object([
            "navigationFence": .object([
                "admitted": .bool(true),
                "conversationID": .string(conversationID.uuidString),
                "incarnationID": .string(incarnationID.uuidString),
                "requestCorrelationID": .string(requestCorrelationID),
                "epoch": .integer(Int64(epoch)),
                "reason": .string(reason),
            ]),
        ])
    }
}

/// The synchronous admission domain for one accepted generation. Lock-only;
/// safe to consult from binder/JNI threads and from the domain actor. It
/// mirrors the published live session, holds each session's commit-boundary
/// fence, certifies exact retired/absent tuples authoritatively (same lock)
/// and fences START tickets submitted before a navigation landed.
public final class TemporaryNavigationGate: @unchecked Sendable {
    public let epoch: UInt64

    private struct Live {
        let conversationID: UUID
        let incarnation: UUID
        let fence: TemporaryPromotionCommitFence
    }
    struct Tomb {
        let conversationID: UUID
        let incarnation: UUID
        let fence: TemporaryPromotionCommitFence
        var cleanupPending: Bool
    }
    private enum State {
        case empty
        case live(Live)
        case retired                      // generation retirement
    }

    private let lock = NSLock()
    private var state: State = .empty
    /// Bounded tombstone ledger: an end's exact tuple stays certifiable as
    /// `alreadyRetired` (and its async cleanup claimable exactly once) even
    /// after a NEWER session has published — a late processor must never
    /// discard a replacement session, and a replacement never erases the
    /// authoritative discard of the old one.
    private var tombstones: [Tomb] = []
    private static let maximumTombstones = 8
    /// temp.start tickets issued at submit time; a navigation fence marks
    /// every already-submitted ticket refused (mailbox serialization can
    /// otherwise commit a session AFTER the App already navigated away).
    private var pendingStartTickets: Set<String> = []
    private var fencedStartTickets: Set<String> = []
    /// Bounded correlation -> admission decisions recorded by the
    /// synchronous end handler for the async processor to consume exactly
    /// once per receipt. A repeated consultation of the SAME correlation
    /// returns the recorded decision (re-admission of the same tuple
    /// certifies alreadyRetired; the decision itself is never re-derived).
    private var decisionByCorrelation: [(correlation: String,
                                         decision: TemporaryEndAdmission)] = []
    private static let maximumDecisions = 256

    public init(epoch: UInt64) {
        self.epoch = epoch
    }

    // ---- start tickets ----

    /// Called by the synchronous temp.start ingress BEFORE mailbox submit.
    public func issueStartTicket(correlation: String) {
        lock.lock(); pendingStartTickets.insert(correlation); lock.unlock()
    }

    /// Release a ticket whose submit failed (bounded hygiene).
    public func releaseStartTicket(correlation: String) {
        lock.lock(); pendingStartTickets.remove(correlation); lock.unlock()
    }

    /// Publishes the ACTUALLY committed RAM session. Returns false (and
    /// refuses publication) when the generation retired or this ticket was
    /// fenced by a navigation that landed before the start processor ran.
    /// An unregistered correlation is the trusted in-process direct path
    /// (tests/glue that bypass the mailbox); wired mailbox starts always
    /// carry their ticket.
    @discardableResult
    public func publishSession(conversationID: UUID, incarnation: UUID,
                               fence: TemporaryPromotionCommitFence,
                               ticketCorrelation: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if case .retired = state { return false }
        if fencedStartTickets.contains(ticketCorrelation) { return false }
        pendingStartTickets.remove(ticketCorrelation)
        state = .live(Live(conversationID: conversationID,
                           incarnation: incarnation, fence: fence))
        return true
    }

    // ---- end admission (synchronous, authoritative) ----

    /// The TMP-NAV-2 admission point. Performs, under ONE lock section and
    /// with ZERO awaits: identity/root validation, commit-fence flip, live
    /// slot tombstone, pending start fencing, and the authoritative
    /// fenced/alreadyRetired/alreadyAbsent certification.
    public func admitEnd(conversationID: UUID, incarnation: UUID,
                         correlation: String) -> TemporaryEndAdmission {
        lock.lock(); defer { lock.unlock() }
        let decision: TemporaryEndAdmission
        switch state {
        case .retired:
            decision = .refused(TemporaryDomainError(.invalidState,
                                                     .generationRetired))
        case .live(let live):
            if live.conversationID != conversationID {
                decision = .refused(TemporaryDomainError(.notFound,
                                                         .sessionNotCurrent))
            } else if live.incarnation != incarnation {
                decision = .refused(TemporaryDomainError(.staleRevision,
                                                         .incarnationMismatch))
            } else {
                // FIRST synchronous fence: flip the commit-boundary fence,
                // ledger the tombstone (cleanup pending), fence every
                // queued start ticket, and move the live slot to empty so
                // late admissions can never operate on the old tuple.
                live.fence.flip()
                tombstones.append(Tomb(conversationID: conversationID,
                                       incarnation: incarnation,
                                       fence: live.fence,
                                       cleanupPending: true))
                if tombstones.count > Self.maximumTombstones {
                    tombstones.removeFirst(tombstones.count - Self.maximumTombstones)
                }
                pendingStartTickets.forEach { fencedStartTickets.insert($0) }
                state = .empty
                decision = .fenced(conversationID: conversationID,
                                   incarnation: incarnation)
            }
        case .empty:
            // Authoritative absence certification is exact: this generation
            // currently owns NO live session; the requested tuple either
            // never published (absent) or was already fenced+consumed
            // (retired). The ledger decides which truth to tell.
            if tombstones.contains(where: {
                $0.conversationID == conversationID && $0.incarnation == incarnation
            }) {
                // Ledger-certified discard: exact alreadyRetired. Cleanup
                // claims are separately exactly-once (`consumeCleanup`); a
                // second end for the same tuple NEVER re-claims them.
                decision = .alreadyRetired(conversationID: conversationID,
                                           incarnation: incarnation)
            } else {
                decision = .alreadyAbsent(conversationID: conversationID)
                pendingStartTickets.forEach { fencedStartTickets.insert($0) }
            }
        }
        decisionByCorrelation.append((correlation, decision))
        if decisionByCorrelation.count > Self.maximumDecisions {
            decisionByCorrelation.removeFirst(
                decisionByCorrelation.count - Self.maximumDecisions)
        }
        return decision
    }

    /// The async processor consults the recorded synchronous decision for
    /// its own correlation (absence means the trusted direct path — the
    /// caller then admits freshly through `admitEnd`).
    public func decision(correlation: String) -> TemporaryEndAdmission? {
        lock.lock(); defer { lock.unlock() }
        return decisionByCorrelation.last { $0.correlation == correlation }?.decision
    }

    /// Exactly-once cleanup claim for a first actual fence. The FIRST
    /// consumer receives the session's fence (so the actor can prove the
    /// flip identity); duplicates and retired/absent certifications return
    /// nil and never clean a second time.
    public func consumeCleanup(conversationID: UUID,
                               incarnation: UUID) -> TemporaryPromotionCommitFence? {
        lock.lock(); defer { lock.unlock() }
        guard let index = tombstones.firstIndex(where: {
            $0.conversationID == conversationID
                && $0.incarnation == incarnation && $0.cleanupPending
        }) else { return nil }
        let fence = tombstones[index].fence
        tombstones[index].cleanupPending = false
        return fence
    }

    // ---- late-mutation admission checks (keep/launch/save) ----

    /// True ONLY when the exact tuple has actually been discarded (fenced,
    /// cleanup pending or done) or the generation retired. A REPLACED tuple
    /// is NOT blocked here: the actor's identity rules answer the precise
    /// frozen refusals (`sessionNotCurrent` / `incarnationMismatch`), never
    /// a widened tombstone classification.
    public func blocksOperations(conversationID: UUID, incarnation: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .retired: return true
        case .live(let live):
            // The LIVE tuple is operable; any older tuple that is also in
            // the ledger is blocked.
            if live.conversationID == conversationID,
               live.incarnation == incarnation { return false }
            return tombstones.contains {
                $0.conversationID == conversationID && $0.incarnation == incarnation
            }
        case .empty:
            return tombstones.contains {
                $0.conversationID == conversationID && $0.incarnation == incarnation
            }
        }
    }

    /// Snapshot of the live published identity (status/hints; never an
    /// authority for mutation).
    public func liveIdentity() -> (conversationID: UUID, incarnation: UUID)? {
        lock.lock(); defer { lock.unlock() }
        if case .live(let live) = state {
            return (live.conversationID, live.incarnation)
        }
        return nil
    }

    public var isRetired: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .retired = state { return true }
        return false
    }

    /// Retirement: fence everything, refuse all pending starts. Idempotent.
    public func retire() {
        lock.lock(); defer { lock.unlock() }
        if case .live(let live) = state { live.fence.flip() }
        pendingStartTickets.forEach { fencedStartTickets.insert($0) }
        state = .retired
    }

    /// The trusted DIRECT end path (in-process glue / unit tests) mirrors
    /// its synchronous inline fence into the gate so later admission
    /// consults see the same authoritative tombstone. Never a second
    /// cleanup claim (the inline path performed the cleanup itself).
    public func forceTombstone(conversationID: UUID, incarnation: UUID,
                               fence: TemporaryPromotionCommitFence) {
        lock.lock(); defer { lock.unlock() }
        if case .live(let live) = state,
           live.conversationID == conversationID,
           live.incarnation == incarnation {
            state = .empty
        }
        if !tombstones.contains(where: {
            $0.conversationID == conversationID && $0.incarnation == incarnation
        }) {
            tombstones.append(Tomb(conversationID: conversationID,
                                   incarnation: incarnation,
                                   fence: fence, cleanupPending: false))
            if tombstones.count > Self.maximumTombstones {
                tombstones.removeFirst(tombstones.count - Self.maximumTombstones)
            }
        }
    }

    /// Test/retirement hygiene: drop the recorded decisions and tickets of
    /// an epoch whose domain is being uninstalled. The retired STATE is
    /// never resurrected by this — it only bounds the auxiliary maps.
    internal func clearAuxiliaryStateForTesting() {
        lock.lock()
        decisionByCorrelation.removeAll()
        pendingStartTickets.removeAll()
        fencedStartTickets.removeAll()
        lock.unlock()
    }
}

// MARK: - Frozen temporary provenance (feed/learning exclusion)

/// The frozen-at-start truth for every row and run of one temporary
/// session. Carried by the committed Keep receipt so the ordinary post-Keep
/// surfaces can NEVER treat historical temporary messages/runs as fresh
/// ordinary learning material just because the durable rows now say
/// `purpose == 'ordinary'`. Identifiers/flags only — never content.
public struct TemporaryFrozenProvenance: Sendable, Equatable {
    public let temporaryAtStart: Bool      // always true by construction
    public let frozenTemporaryRun: Bool    // always true by construction
    public let conversationID: UUID
    public let incarnation: UUID
    public init(conversationID: UUID, incarnation: UUID) {
        self.temporaryAtStart = true
        self.frozenTemporaryRun = true
        self.conversationID = conversationID
        self.incarnation = incarnation
    }
}

// MARK: - Immutable temporary store bundle

/// The session's ORIGINAL Ephemeral stores as one immutable bundle handed
/// to the real run service BEFORE its first await. The production adapter
/// maps this onto `RunPersistenceBundle` (`identity: .temporary`,
/// `childRuns: nil`, `intelligence: nil`, `discovery: nil`) — children stay
/// in-memory, goal mode is refused at admission, and no discovery
/// projection is persisted while temporary.
public struct TemporaryStoreBundle: Sendable {
    public let hostedConversationID: UUID
    public let conversations: EphemeralConversationStore
    public let runs: EphemeralRunStore
    public let runningInputs: EphemeralRunningInputStore
    public let launches: EphemeralRunLaunchStore
    /// The immutable temporary identity marker (never mutable, never
    /// inferred later from durable rows).
    public let isTemporary: Bool

    public init(hostedConversationID: UUID,
                conversations: EphemeralConversationStore,
                runs: EphemeralRunStore,
                runningInputs: EphemeralRunningInputStore,
                launches: EphemeralRunLaunchStore) {
        self.hostedConversationID = hostedConversationID
        self.conversations = conversations
        self.runs = runs
        self.runningInputs = runningInputs
        self.launches = launches
        self.isTemporary = true
    }

    /// Close every participating store. After this point late appends fail
    /// closed with the original gate error. Never resurrects anything.
    public func closeAll() async {
        await conversations.close()
        await runs.close()
        await runningInputs.close()
    }

    /// Gateway state snapshot for the truthful pre/post-commit failure
    /// classification (RB4/native pattern: forwarded flags, not booleans
    /// guessed after awaits).
    public func gatewayStates() async -> (conversationForwarded: Bool,
                                          runForwarded: Bool,
                                          inputForwarded: Bool) {
        (await conversations.isForwarded,
         await runs.isForwarded,
         await runningInputs.isForwarded)
    }
}

// MARK: - Live route view for the ORDINARY command facade

/// Read-only routing view of the ONE live temporary session, handed to the
/// ordinary conversation/run facade so its EXISTING command contracts
/// (`conversation.get`, `conversation.messagePage`, `run.start`,
/// `run.snapshot`, `run.cancel`, `event.poll`) address the session's REAL
/// original `Ephemeral*` stores instead of the durable SQLite cluster.
///
/// This is identity + the SAME store references the session committed; it
/// carries no mutable authority and no content. Every caller re-validates
/// the exact incarnation against the domain AFTER reading (a session that
/// ended mid-read is a typed notFound, never a resurrected empty surface).
public struct TemporaryLiveRoute: Sendable {
    public let conversationID: UUID
    public let incarnation: UUID
    public let epoch: UInt64
    public let frozenToolCeiling: Set<String>
    public let stores: TemporaryStoreBundle

    public init(conversationID: UUID, incarnation: UUID, epoch: UInt64,
                frozenToolCeiling: Set<String>, stores: TemporaryStoreBundle) {
        self.conversationID = conversationID
        self.incarnation = incarnation
        self.epoch = epoch
        self.frozenToolCeiling = frozenToolCeiling
        self.stores = stores
    }

    /// The frozen temporary revision spelling (`session.<id>/<incarnation>`);
    /// the App's ordinary `run.start` envelope carries exactly this.
    public var revisionResourceID: String {
        TemporarySessionRevision.resourceID(conversationID: conversationID)
    }
    public var revisionVersion: String {
        TemporarySessionRevision.version(incarnation: incarnation)
    }

    /// The SAME ephemeral bundle the RB5 launch port hands to the run
    /// service before its first await. Used ONLY for reads here
    /// (`run.snapshot`, `child.*`) — launches still travel
    /// `FacadeTemporaryDomain.temporaryLaunch`.
    public var runBundle: RunPersistenceBundle {
        RunPersistenceBundle(
            identity: .temporary,
            conversations: stores.conversations,
            runs: stores.runs,
            runningInputs: stores.runningInputs,
            launches: stores.launches,
            childRuns: nil,
            intelligence: nil)
    }
}

// MARK: - Typed run-domain port (REQUIRED, never noop)

/// One temporary launch request. Attachments/staged handles are refused
/// structurally BEFORE this port is ever called; a non-empty count is a
/// typed refusal, never a silent drop. `receipt` is the mailbox operation
/// receipt whose stream the REAL run domain appends its
/// `prepared`/`started` stages onto — the SAME reviewed RB1 channel.
public struct TemporaryLaunchRequest: Sendable {
    public let conversationID: UUID
    public let incarnation: UUID
    public let epoch: UInt64
    public let correlation: String
    public let receipt: String?
    public let goal: String
    /// ORIGINAL RunLaunchStore mode vocabulary (chat | plan | goal). The
    /// facade refuses goal for temporary sessions and never introduces a
    /// new mode.
    public let mode: String
    public let preferredModelID: UUID?
    /// The frozen per-session public-web ceiling (names). The run lane
    /// INTERSECTS with it; it can never widen it.
    public let frozenToolCeiling: Set<String>
    public let stores: TemporaryStoreBundle
    public init(conversationID: UUID, incarnation: UUID, epoch: UInt64,
                correlation: String, receipt: String?, goal: String,
                mode: String, preferredModelID: UUID?,
                frozenToolCeiling: Set<String>, stores: TemporaryStoreBundle) {
        self.conversationID = conversationID
        self.incarnation = incarnation
        self.epoch = epoch
        self.correlation = correlation
        self.receipt = receipt
        self.goal = goal
        self.mode = mode
        self.preferredModelID = preferredModelID
        self.frozenToolCeiling = frozenToolCeiling
        self.stores = stores
    }
}

public enum TemporaryLaunchReply: Sendable {
    /// The real run domain started an owned run for the temporary bundle.
    /// `runID` comes from the ORIGINAL Swift-domain mint (RB4 start).
    case launched(runID: UUID)
    /// Typed refusal (never a fake success, never a noop stream).
    case refused(TemporaryDomainError)
}

/// The REQUIRED typed integration port onto the real run service. The
/// production implementation is `RuntimeFacadeTemporaryRunAdapter` ONLY;
/// an unbound port is a typed `needsConfiguration{runDomainUnbound}`
/// refusal on every affected route — never a production noop or a simulated
/// model stream.
public protocol TemporaryRunDomainPort: Sendable {
    /// Launch (or continue) a run inside the exact live temporary session.
    /// The callee must hand the SAME `stores` bundle plus the frozen
    /// `.temporary` identity to the service BEFORE its first await.
    func launchTemporary(_ request: TemporaryLaunchRequest) async -> TemporaryLaunchReply
    /// Explicit service cancellation for one owned temporary run (the
    /// ORIGINAL `ConversationRunService.cancel()` semantics). Dispatch
    /// only: the run owner detaches its RB1 tokens after its REAL final
    /// writes, never here and never on a timeout.
    func cancelTemporaryRun(conversationID: UUID, incarnation: UUID,
                            runID: UUID, epoch: UInt64) async
    /// True while the port holds live owned work for this exact run of the
    /// session identity. Read-only; honest status only, never fencing.
    func hasLiveTemporaryRun(conversationID: UUID, incarnation: UUID,
                             runID: UUID) async -> Bool
}

// MARK: - Typed web-search availability port (D1 closure)

/// The host's provider-readiness view for the two provider-backed public
/// web search tools. Unconfigured provider-backed search is NEVER
/// advertised: it leaves the ceiling before the ceiling freezes. An absent
/// port means conservative composition (both search names drop; the
/// providerless `web.fetch` stays), typed into the session status as
/// `availabilityUnbound`. It is NOT a launch authority.
public protocol TemporaryWebSearchAvailabilityProviding: Sendable {
    func isConfigured(toolName: String) async -> Bool
}

// MARK: - Typed host-surface port (navigation/draft acknowledgement)

/// The host-side RAM surface for the exact session: composer draft bucket,
/// projections, content handles. Notifications only — the gate/slot
/// tombstone is the authority and never depends on this port. The Android
/// production composition passes NIL (the App feature layer keeps its own
/// draft RAM under the exact hosted id/incarnation and clears it on the
/// matching callbacks); the port remains the documented acknowledgement
/// channel and the exclusion invariants (Keep migrates the unsent draft
/// exactly once, End drops it) stay asserted against the ORIGINAL native
/// contract.
public protocol TemporaryHostSurfaceProviding: Sendable {
    func surfaceAdopted(conversationID: UUID, incarnation: UUID,
                        draftVerbatim: String?) async
    func surfaceDiscarded(conversationID: UUID, incarnation: UUID) async
    func surfacePromoted(conversationID: UUID, incarnation: UUID,
                         durableConversationID: UUID) async
}

// MARK: - Host lifecycle hints (typed integration, NEVER navigation)

/// Foreground/background/lock hints (temp retention): NONE of these may
/// discard a session, cancel a run or change a route (TMP-NAV-DISCARD
/// negative). Recorded only as typed status facts.
public enum TemporaryHostLifecycleHint: String, Sendable, CaseIterable {
    case background
    case inactive
    case foreground
    case locked
    case unlocked
    case rotation
    case configurationChange
    case viewReconstruction
}

public enum TemporaryLifecycleAck: Sendable, Equatable {
    /// A live session exists and is PRESERVED (run/route untouched).
    case preserved(conversationID: UUID, incarnation: UUID)
    /// No session to preserve (nothing happened — never an error).
    case noSession
}

// MARK: - Read-only session authority view (follow-up turn handoff)

/// The typed authority the run lane needs to prove a presentation belongs
/// to the LIVE temporary session. Returns nil for a tombstoned/replaced
/// session: an old callback can never act on a replacement session or a
/// different incarnation.
public struct TemporaryConversationAuthority: Sendable {
    public let conversationID: UUID
    public let incarnation: UUID
    public let epoch: UInt64
    public let revisionResourceID: String
    public let revisionVersion: String
    public let frozenToolCeiling: Set<String>
    public let stores: TemporaryStoreBundle
    public init(conversationID: UUID, incarnation: UUID, epoch: UInt64,
                frozenToolCeiling: Set<String>, stores: TemporaryStoreBundle) {
        self.conversationID = conversationID
        self.incarnation = incarnation
        self.epoch = epoch
        self.revisionResourceID = TemporarySessionRevision.resourceID(conversationID: conversationID)
        self.revisionVersion = TemporarySessionRevision.version(incarnation: incarnation)
        self.frozenToolCeiling = frozenToolCeiling
        self.stores = stores
    }
}

// MARK: - Payload + limits

/// Closed payload bounds for the temporary commands. The frozen 64 KiB
/// per-envelope bound already applies upstream (BridgeV3 + mailbox).
public enum TemporaryDomainLimits {
    public static let maximumDraftBytes = 32_768
    public static let maximumGoalBytes = 65_536
    public static let maximumPayloadKeys = 4
}

/// Strict closed-object payload reader for the temporary commands (no
/// unknown keys, no nested authority). Deliberately self-contained.
public enum TemporaryPayloadReader {
    public struct UnknownKey: Error {}

    public static func keys(_ object: [String: Any]?) throws -> Set<String> {
        guard let object else { return [] }
        guard object.count <= TemporaryDomainLimits.maximumPayloadKeys else {
            throw TemporaryDomainError(.payloadTooLarge, .payloadTooLarge)
        }
        return Set(object.keys)
    }

    public static func optionalString(_ object: [String: Any]?, _ key: String,
                                      maxBytes: Int) throws -> String? {
        guard let raw = object?[key] else { return nil }
        guard let value = raw as? String else {
            throw TemporaryDomainError(.invalidState, .payloadInvalid)
        }
        guard value.utf8.count <= maxBytes else {
            throw TemporaryDomainError(.payloadTooLarge, .payloadTooLarge)
        }
        return value
    }

    public static func optionalUUID(_ object: [String: Any]?, _ key: String) throws -> UUID? {
        guard let raw = object?[key] else { return nil }
        guard raw is String, let uuid = UUID(uuidString: raw as! String),
              uuid != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else {
            throw TemporaryDomainError(.invalidState, .payloadInvalid)
        }
        return uuid
    }
}
