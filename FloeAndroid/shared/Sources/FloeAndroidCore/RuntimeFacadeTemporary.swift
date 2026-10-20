// SPDX-License-Identifier: MPL-2.0
//
// RB-5 temporary session — ONE service-owned RAM-only temporary session
// context per accepted generation epoch, with navigation tombstone and the
// atomic Keep pipeline.
//
// Behavioral reference (ORIGINAL native authority — FloeApp/Remote/
// ConversationCenter.swift, temporary lifecycle :1790-2420, store routing
// :1634-1653; mirrored semantics, NOT copied UI):
// * `startTemporarySession` (:1851-1877) — a new session never inherits a
//   previous attempt's frozen context or promoted identity; one session at a
//   time (a second start is refused, never queued behind the first); fresh
//   incarnation per session even when a conversation id could be reused;
//   the draft rides verbatim into the RAM-only bucket.
// * `endTemporaryChat` (:1933-2064) — an actual leave destroys the session
//   IMMEDIATELY: identity/incarnation check → tombstone → fence invalidate
//   → owned-run bookkeeping removal → RAM draft clear all happen
//   SYNCHRONOUSLY before any await, so a slow/blocked Keep can never leave a
//   live resumable temporary surface behind, and a late callback from an old
//   view/route can never destroy, clear or navigate a replacement session.
//   Background/inactive/lock is NOT a leave and never reaches this path.
// * `performKeep` (:2186-2345) — beginPromotion across ALL participating
//   stores freezes the watermark snapshot → ONE promoter transaction (here
//   additionally under the owner-controlled commit fence) → completePromotion
//   forwards the post-watermark tail in original order with the original
//   once-only semantics → pre-commit failure aborts with RAM fully intact;
//   post-commit failure keeps the frozen context pinned so the retry resumes
//   the failed gateway step EXACTLY once (no double insert, no re-begin, no
//   false "nothing saved" rollback claim).
//
// Facade additions mandated by the G02 contract:
// * The commit fence (support file) replaces the "check a boolean after the
//   await" pattern at the ONLY point that matters — inside the promoter's
//   writer transaction. Navigation across a blocked commit therefore cannot
//   persist discarded content; a Keep whose commit truly completed first
//   remains ordinary truth (the native "only genuinely committed durable
//   rows survive" contract).
// * Owned-work attachment: one REAL reviewed RB1 registry entry
//   (`RuntimeOwnedWorkRegistry.shared`, kind `.conversation`, ownerID = the
//   hosted conversation id) covers the promotion's durable write + tail
//   settlement. Attach BEFORE the owned work starts; detach ONLY after real
//   completion or final failure (after the abort/rollback truth is recorded)
//   — never on caller cancellation, timeout or UI teardown. A registry
//   refusal is conservative: the Keep is refused pre-effect with zero
//   durable rows.
// * The temp.end/temp.keep envelopes must carry the REAL hosted
//   conversation id as taskID and `session.<conversationID>/<incarnation>`
//   as the revision; scope/incarnation/epoch/correlation are validated
//   before ANY effect (the synchronous submit handler already enforced the
//   generation epoch + mailbox admission; this actor proves identity before
//   touching stores).
//
// This source is NOT compiled, NOT executed and NOT registered by the
// authoring package.
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloePersistence

// MARK: - Components

/// Everything one generation's temporary domain composes. The durable
/// targets are the SAME schema-46 `DatabaseManager` store cluster owned by
/// the trusted generation (RB1 `AndroidRuntimeStoreOwner`); this package
/// never opens a database, never chooses a root and never adds a schema,
/// journal or promotion DB. An absent optional port is typed, never a
/// silent noop: the run port is REQUIRED at install, web-search availability
/// composes conservatively, and the host surface is a documented
/// acknowledgement channel.
public struct TemporaryDomainComponents: Sendable {
    public let epoch: UInt64
    /// The TMP-NAV-2 synchronous admission domain for this generation.
    public let gate: TemporaryNavigationGate
    /// The reviewed RB1 effect pump for this generation (prepared stages +
    /// the single command terminal ride the SAME operation receipt stream).
    public let effects: FacadeEffectPump
    public let database: DatabaseManager
    public let durableConversations: any ConversationStore
    public let durableRuns: any RunStore
    public let durableRunningInputs: any RunningInputStore
    /// The catalog the run lane will ACTUALLY dispatch from; the temporary
    /// ceiling is composed from these real descriptors through the original
    /// FloeTools policy, never from a payload or model-supplied list.
    public let toolRegistry: ToolRunnerRegistry
    public let runPort: any TemporaryRunDomainPort
    public let webSearchAvailability: (any TemporaryWebSearchAvailabilityProviding)?
    public let hostSurface: (any TemporaryHostSurfaceProviding)?

    public init(epoch: UInt64, gate: TemporaryNavigationGate,
                effects: FacadeEffectPump,
                database: DatabaseManager,
                durableConversations: any ConversationStore,
                durableRuns: any RunStore,
                durableRunningInputs: any RunningInputStore,
                toolRegistry: ToolRunnerRegistry,
                runPort: any TemporaryRunDomainPort,
                webSearchAvailability: (any TemporaryWebSearchAvailabilityProviding)?,
                hostSurface: (any TemporaryHostSurfaceProviding)?) {
        self.epoch = epoch
        self.gate = gate
        self.effects = effects
        self.database = database
        self.durableConversations = durableConversations
        self.durableRuns = durableRuns
        self.durableRunningInputs = durableRunningInputs
        self.toolRegistry = toolRegistry
        self.runPort = runPort
        self.webSearchAvailability = webSearchAvailability
        self.hostSurface = hostSurface
    }
}

// MARK: - Domain

/// One instance per accepted generation epoch (NOT MainActor). All session
/// state lives here — never in a view, binder callback or envelope.
public actor FacadeTemporaryDomain {

    // MARK: Session state

    /// Promotion sub-state inside one live session (mirrors the native
    /// `TemporaryChatSession.PromotionState` with the truthful tail case).
    enum PromotionState: Sendable, Equatable {
        case idle
        case inFlight(idempotencyKey: UUID)
        /// Post-commit tail failure: the durable conversation EXISTS (id);
        /// a repeated Keep resumes the failed gateway step exactly once.
        case tailPending(durable: UUID)
    }

    /// Frozen inputs of an in-flight/resumable promotion (the native
    /// `PromotionAttemptContext`): pinned so a retry after a post-commit
    /// failure never re-runs `beginPromotion` against an already-promoting
    /// or forwarded store and never re-races stream appends.
    struct PromotionAttemptContext: Sendable {
        let sessionID: UUID
        let incarnation: UUID
        let idempotencyKey: UUID
        var saved: ConversationRecord
        var conversationSnapshot: EphemeralConversationStore.Snapshot
        var runSnapshot: EphemeralRunStore.Snapshot
        var inputSnapshot: [PendingUserInput]
        /// The frozen feed/learning exclusion truth carried into the
        /// committed receipt (never re-derived from the post-Keep row).
        let provenance: TemporaryFrozenProvenance
    }

    /// The ONE live temporary session. `fence` is the session's
    /// owner-controlled commit fence: flipped synchronously at the moment
    /// of tombstone (end/retirement), so every in-flight or later Keep of
    /// THIS incarnation is authoritatively refused inside the promoter
    /// transaction.
    struct Session: Sendable {
        let conversationID: UUID
        let incarnation: UUID
        let epoch: UInt64
        let stores: TemporaryStoreBundle
        let ceiling: Set<String>
        let ceilingAvailabilityUnbound: Bool
        let preferredModelID: UUID?
        let fence: TemporaryPromotionCommitFence
        let provenance: TemporaryFrozenProvenance
        var promotion: PromotionState = .idle
        var attempt: PromotionAttemptContext?
        /// Owned temporary run ids launched through this session (the
        /// ORIGINAL run ids minted by the run lane, never dummies).
        var ownedRunIDs: Set<UUID> = []
        /// The in-flight Keep command's mailbox correlation, so the
        /// session-side marker is cleared only by its own completion.
        var keepCorrelation: String?
    }

    /// A committed Keep's durable receipt (the native
    /// `lastPromotedConversationID` + idempotent-retry contract). Cleared
    /// when a new session starts.
    struct PromotedReceipt: Sendable {
        let hostedConversationID: UUID
        let incarnation: UUID
        let durableConversationID: UUID
    }

    /// Deterministic test seams (NEVER set in production; mirrors the
    /// original `ToggleTestHooks` / `PromotionTestHooks` discipline):
    /// called at exact suspend points so the navigation-across-blocked-keep
    /// and late-callback races are staged without unbounded sleeps.
    struct TestHooks: Sendable {
        /// Runs after the RAM session commit and before the prepared
        /// effect append (staged late-publish races for start).
        var afterRAMCommit: (@Sendable () async -> Void)?
        /// Runs with the 1-based gateway step number before each
        /// completePromotion; throwing fails that step.
        var beforeGatewayStep: (@Sendable (Int) async throws -> Void)?
        /// Runs after the frozen watermark snapshot and BEFORE the promoter
        /// transaction is dispatched (stages the navigation-across-blocked-
        /// commit race without unbounded sleeps).
        var afterFreezeBeforeCommit: (@Sendable () async -> Void)?
        /// Runs after the promoter transaction returns committed and
        /// before the tail gateway steps (stages commit-vs-end races).
        var afterCommit: (@Sendable () async -> Void)?
    }
    var testHooks = TestHooks()

    /// Test-only configuration of the staged seams (each parameter nil
    /// clears that seam). Never called by a production path.
    internal func setTestHooksForTesting(
        afterRAMCommit: (@Sendable () async -> Void)? = nil,
        afterFreezeBeforeCommit: (@Sendable () async -> Void)? = nil,
        beforeGatewayStep: (@Sendable (Int) async throws -> Void)? = nil,
        afterCommit: (@Sendable () async -> Void)? = nil) {
        testHooks = TestHooks(afterRAMCommit: afterRAMCommit,
                              beforeGatewayStep: beforeGatewayStep,
                              afterFreezeBeforeCommit: afterFreezeBeforeCommit,
                              afterCommit: afterCommit)
    }

    private let components: TemporaryDomainComponents
    private let promoter: ConversationPromoter
    private var session: Session?
    private var lastPromoted: PromotedReceipt?

    public init(components: TemporaryDomainComponents) {
        self.components = components
        self.promoter = ConversationPromoter(database: components.database)
    }

    // MARK: - Honest status (typed, for the trusted host glue only)

    public struct StatusSnapshot: Sendable, Equatable {
        public var active: Bool
        public var conversationID: UUID?
        public var incarnation: UUID?
        public var promotion: String        // idle | inFlight | tailPending
        public var ownedRunCount: Int
        public var ceilingNameCount: Int
        public var availabilityUnbound: Bool
    }

    public func status() -> StatusSnapshot {
        guard let session else {
            return StatusSnapshot(active: false, conversationID: nil,
                                  incarnation: nil, promotion: "idle",
                                  ownedRunCount: 0, ceilingNameCount: 0,
                                  availabilityUnbound: false)
        }
        let promotion: String
        switch session.promotion {
        case .idle: promotion = "idle"
        case .inFlight: promotion = "inFlight"
        case .tailPending: promotion = "tailPending"
        }
        return StatusSnapshot(active: true,
                              conversationID: session.conversationID,
                              incarnation: session.incarnation,
                              promotion: promotion,
                              ownedRunCount: session.ownedRunIDs.count,
                              ceilingNameCount: session.ceiling.count,
                              availabilityUnbound: session.ceilingAvailabilityUnbound)
    }

    /// The read-only authority view consumed by the host glue to prove a
    /// run-lane presentation belongs to the LIVE temporary session (see
    /// HANDOFF §RB4 routing). Returns nil for a tombstoned/replaced session;
    /// an old callback can therefore never observe authority for a NEW
    /// session at a reused id, and never for a different incarnation.
    public func authority(conversationID: UUID,
                          incarnation: UUID) -> TemporaryConversationAuthority? {
        guard let session,
              session.conversationID == conversationID,
              session.incarnation == incarnation else { return nil }
        return TemporaryConversationAuthority(
            conversationID: session.conversationID,
            incarnation: session.incarnation,
            epoch: session.epoch,
            frozenToolCeiling: session.ceiling,
            stores: session.stores)
    }

    /// Read-only live route for the ORDINARY conversation/run facade. Returns
    /// the exact session identity + the SAME original ephemeral store
    /// references only while THIS hosted conversation is the live session;
    /// nil for an ordinary conversation, a tombstoned/discarded tuple, a
    /// promoted session or a different incarnation. Never a mutation path,
    /// never a durable fallback and never a synthetic empty session — the
    /// caller re-checks this same value after its reads.
    public func liveRoute(conversationID: UUID) -> TemporaryLiveRoute? {
        // A retired generation never routes ordinary commands into a RAM
        // session, even if a late actor job still holds this reference.
        guard !components.gate.isRetired else { return nil }
        guard let session, session.conversationID == conversationID else {
            return nil
        }
        // Authoritative navigation tombstone: a fenced tuple never serves an
        // ordinary read/launch even during the small async cleanup window.
        guard !components.gate.blocksOperations(
            conversationID: conversationID,
            incarnation: session.incarnation) else { return nil }
        return TemporaryLiveRoute(
            conversationID: session.conversationID,
            incarnation: session.incarnation,
            epoch: session.epoch,
            frozenToolCeiling: session.ceiling,
            stores: session.stores)
    }

    // MARK: - temp.start (launch scope, create intent, no taskID)

    /// One validated mailbox job of `temp.start`. Identities are minted and
    /// become authoritative ONLY here, after the RAM session is actually
    /// committed to the domain slot — the queue receipt already settled in
    /// the synchronous handler with correlation + receipt ONLY.
    ///
    /// Refusals (all typed, zero effects beyond the terminal): a session is
    /// already active (`invalidState{sessionAlreadyInFlight}` — the native
    /// "End the current temporary chat first" rule); payload keys outside
    /// the closed {draft, preferredModelID} set; retirement in progress.
    public func start(envelope object: [String: Any], receipt: String?,
                      correlation: String) async -> TemporaryDomainReply {
        // Generation fence: `currentPumps` already refused a retiring epoch
        // at submit; re-prove here so a retired replacement can never be
        // written by a stale job (defense in depth, pre-effect).
        guard session == nil else {
            // Native rule: "End the current temporary chat first" — a
            // second start is refused, never queued behind the first.
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.invalidState, .anotherSessionActive)))
        }
        let payload: [String: Any]?
        do {
            guard try TemporaryPayloadReader.keys(object["payload"] as? [String: Any])
                .isSubset(of: ["draft", "preferredModelID"]) else {
                throw TemporaryDomainError(.invalidState, .payloadInvalid)
            }
            payload = object["payload"] as? [String: Any]
            // Bounds-checked even when a key is absent.
            _ = try TemporaryPayloadReader.optionalString(
                payload, "draft", maxBytes: TemporaryDomainLimits.maximumDraftBytes)
            _ = try TemporaryPayloadReader.optionalUUID(payload, "preferredModelID")
        } catch let error as TemporaryDomainError {
            return TemporaryDomainReply(.rejected(error))
        } catch {
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.invalidState, .payloadInvalid)))
        }
        let draft = ((try? TemporaryPayloadReader.optionalString(
            payload, "draft", maxBytes: TemporaryDomainLimits.maximumDraftBytes)) ?? nil)
        let preferredModelID = ((try? TemporaryPayloadReader.optionalUUID(
            payload, "preferredModelID")) ?? nil)

        // ---- Actual host native identity allocator ----
        // Fresh hosted conversation id + fresh incarnation per session,
        // minted by THIS Swift domain (never supplied by the envelope,
        // model or UI). No run/env/job identity exists at this point and
        // none is fabricated.
        let hostedID = UUID()
        let incarnation = UUID()

        // Compose the ceiling from the REAL offered descriptors through the
        // ORIGINAL canonical policy, then apply the provider-readiness
        // (D1) closure: unconfigured provider-backed search is never
        // advertised. This is presentation/composition authority; the
        // runtime STILL re-validates every main and child call per call
        // via Configuration.temporaryReadOnly (never a disabled filter).
        var ceiling = TemporaryChatToolPolicy.allowedToolNames(
            from: components.toolRegistry.allDescriptors)
        var availabilityUnbound = false
        if let provider = components.webSearchAvailability {
            for name in TemporaryChatToolPolicy.providerBackedWebSearchToolNames {
                let configured = await provider.isConfigured(toolName: name)
                if !configured {
                    ceiling.remove(name)
                }
            }
        } else {
            // Conservative closure with an unbound availability port: an
            // unconfigured provider-backed service must never be advertised,
            // so BOTH search names drop and only providerless `web.fetch`
            // remains. Typed into the status; never a fake-ready web.
            availabilityUnbound = true
            for name in TemporaryChatToolPolicy.providerBackedWebSearchToolNames {
                ceiling.remove(name)
            }
        }

        // Build the ORIGINAL ephemeral stores (RAM-only by construction;
        // upstream EphemeralStores.swift touches no GRDB, file, defaults or
        // keychain — verified against pinned bytes c04085b0).
        let record = ConversationRecord(
            id: hostedID,
            title: "",
            createdAt: Date(),
            updatedAt: Date(),
            purpose: .temporary)
        let conversationStore = EphemeralConversationStore(record: record)
        let runStore = EphemeralRunStore(hostedConversationID: hostedID)
        let inputStore = EphemeralRunningInputStore(hostedConversationID: hostedID)
        let launchStore = EphemeralRunLaunchStore(
            hostedConversationID: hostedID,
            conversationStore: conversationStore,
            runStore: runStore)
        let stores = TemporaryStoreBundle(
            hostedConversationID: hostedID,
            conversations: conversationStore,
            runs: runStore,
            runningInputs: inputStore,
            launches: launchStore)

        let fence = TemporaryPromotionCommitFence(
            sessionConversationID: hostedID, sessionIncarnation: incarnation)
        let session = Session(
            conversationID: hostedID,
            incarnation: incarnation,
            epoch: components.epoch,
            stores: stores,
            ceiling: ceiling,
            ceilingAvailabilityUnbound: availabilityUnbound,
            preferredModelID: preferredModelID,
            fence: fence,
            provenance: TemporaryFrozenProvenance(conversationID: hostedID,
                                                  incarnation: incarnation))
        // A new session never inherits a previous promotion context or the
        // last promoted identity (native :1861-1863).
        self.session = session
        self.lastPromoted = nil

        // Staged late-publish seam (deterministic; production nil).
        await testHooks.afterRAMCommit?()

        // The RAM session is committed. If an end/retirement landed during
        // the staging seam, the slot is gone — the session was truly NOT
        // accepted, so refuse without any effect and without resurrecting.
        guard self.session?.incarnation == incarnation else {
            await stores.closeAll()
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.sessionDiscarded, .tombstonedDiscarded)))
        }
        // TMP-NAV-2 publish point: the synchronous gate decides ATOMICALLY
        // whether a navigation that landed while this job was queued fences
        // this ticket (or the generation retired). A refused publication
        // tears the just-built RAM session back down — never resurrects,
        // never persists, never effects.
        guard components.gate.publishSession(conversationID: hostedID,
                                             incarnation: incarnation,
                                             fence: fence,
                                             ticketCorrelation: correlation) else {
            self.session = nil
            await stores.closeAll()
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.sessionDiscarded, .tombstonedDiscarded)))
        }

        // Hosted identity becomes publishable ONLY now (async prepared
        // effect; never in the queue receipt).
        if let receipt {
            components.effects.append(receipt: receipt, kind: .prepared,
                                      detail: ["conversationID": hostedID.uuidString,
                                               "incarnation": incarnation.uuidString])
        }
        if let draft,
           !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Draft rides VERBATIM into the RAM-only bucket.
            await components.hostSurface?.surfaceAdopted(
                conversationID: hostedID, incarnation: incarnation,
                draftVerbatim: draft)
        } else {
            await components.hostSurface?.surfaceAdopted(
                conversationID: hostedID, incarnation: incarnation,
                draftVerbatim: nil)
        }
        // The frozen F7 value carrier: the App binds conversationID +
        // incarnation + the ACTUAL native root epoch from this object.
        // `rootEpoch` is the generation's accepted native Root epoch
        // (MAIN_TEMP_ACK_NATIVE_EPOCH_DECISION; identical to the
        // G02NativeRootEpoch readback) — never a UI counter, never a guess.
        // The detail map keeps the identical identifier-only facts.
        var detail: [String: String] = [
            "session": "active",
            "conversationID": hostedID.uuidString,
            "incarnation": incarnation.uuidString,
            "ceiling": "public-web",
            "rootEpoch": String(components.epoch),
        ]
        var value: [String: DesignJSONValue] = [
            "session": .string("active"),
            "conversationID": .string(hostedID.uuidString),
            "incarnation": .string(incarnation.uuidString),
            "ceiling": .string("public-web"),
            "rootEpoch": .integer(Int64(components.epoch)),
        ]
        if availabilityUnbound {
            detail["availabilityUnbound"] = "true"
            value["availabilityUnbound"] = .bool(true)
        }
        return TemporaryDomainReply(.mutationAccepted(
            detail: detail, value: .object(value)))
    }

    // MARK: - temp.end (conversationLifecycle, synchronous tombstone)

    /// The authoritative end. EVERY refusal-safe state check, the tombstone,
    /// the fence flip and the owned-run bookkeeping capture happen in ONE
    /// synchronous section BEFORE the first await — this is what "detach
    /// the public session before any await" means on a serialized actor:
    /// no other command interleaves between check and tombstone, and no
    /// late callback can act on a session that no longer exists.
    ///
    /// Identity rules (native :1944-1961): no session + scoped caller →
    /// unavailable (no action, no navigation); hosted-id mismatch or
    /// incarnation mismatch → a stale callback must not destroy the NEW
    /// generation → typed refusal.
    public func end(conversationID: UUID, incarnation: UUID,
                    correlation: String? = nil) async -> TemporaryDomainReply {
        let endState: String
        if correlation == nil {
            // Trusted direct path (unit tests / host glue acting
            // synchronously): the full synchronous detach runs inline.
            endState = "fenced"
        } else if consumeEndCleanup(conversationID: conversationID,
                                    incarnation: incarnation) {
            // Wired mailbox path: the synchronous admission ALREADY fenced
            // the session in the binder handler. This is the exactly-once
            // cleanup claim of a first actual fence.
            endState = "fenced"
        } else {
            // No cleanup claim: the tuple was certified alreadyRetired or
            // alreadyAbsent by the synchronous gate, or a duplicate end
            // drained after the first cleanup. Never touch a newer slot.
            return endAccepted(endState: lastEndState(conversationID: conversationID,
                                                      incarnation: incarnation))
        }
        // ---- Synchronous detach: no awaits above the session slot write. ----
        guard let current = session else {
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.notFound, .sessionAbsent)))
        }
        guard current.conversationID == conversationID else {
            // A late callback from an old view must not destroy a new
            // session: refuse WITHOUT acting and without navigating
            // (native `.unavailable` case).
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.notFound, .sessionNotCurrent)))
        }
        guard current.incarnation == incarnation else {
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.staleRevision, .incarnationMismatch)))
        }
        let captured = current
        captured.fence.flip()               // authoritative; idempotent
        session = nil                        // tombstone (slot write)
        lastPromoted = nil                   // end drops the promoted identity
        if correlation == nil {
            // Trusted direct path: mirror the inline fence into the
            // synchronous gate so later admissions certify the same truth.
            // (The wired path was already tombstoned by admitEnd.)
            components.gate.forceTombstone(conversationID: conversationID,
                                           incarnation: incarnation,
                                           fence: captured.fence)
        }

        // ---- Now, and only now, the awaits. ----
        // Close the RAM buffers FIRST so late appends from an unwinding run
        // fail closed instead of buffering into a destroyed session. Never
        // resurrect forwarding on a closed store (original gate contract).
        await captured.stores.closeAll()
        // Explicit service cancellation for each owned run — the ORIGINAL
        // run service's own close, dispatched to the exact run ids this
        // session owned. The port detaches its RB1 tokens only after the
        // run's REAL final writes; this call never waits on a timeout and
        // never detaches on behalf of the run owner.
        for runID in captured.ownedRunIDs {
            await components.runPort.cancelTemporaryRun(
                conversationID: captured.conversationID,
                incarnation: captured.incarnation,
                runID: runID,
                epoch: captured.epoch)
        }
        // Clear the feature RAM draft/projection/content handles of the
        // EXACT session identity — never another route.
        await components.hostSurface?.surfaceDiscarded(
            conversationID: captured.conversationID,
            incarnation: captured.incarnation)

        // A committed Keep that settled before the flip stays ordinary
        // truth; a blocked one is refused by the fence inside the
        // transaction. Nothing here relaunches or waits on it.
        // launchpad-direct temp.start (no owner in the launch envelope):
        // no durable conversation remains (native `.newTask` case). The
        // host's ROUTE gate is the synchronous `value.navigationFence`
        // admission, NOT this terminal — the terminal closes the receipt
        // after the real cleanup. `endState` is the authoritative truth.
        return endAccepted(endState: "fenced")
    }

    /// A refused synchronous admission STILL must settle its queued
    /// receipt's terminal honestly (no cleanup was performed, the session
    /// is untouched).
    public func endRefused(error: TemporaryDomainError) -> TemporaryDomainReply {
        TemporaryDomainReply(.rejected(error))
    }

    private func endAccepted(endState: String) -> TemporaryDomainReply {
        TemporaryDomainReply(.mutationAccepted(
            detail: ["session": "ended", "endRoute": "newTask",
                     "endState": endState],
            value: .object([
                "session": .string("ended"),
                "endRoute": .string("newTask"),
                "endState": .string(endState),
            ])))
    }

    /// Records the authoritative endState the wired synchronous admission
    /// produced for the LAST end (consumed by duplicate/late drains). Set
    /// by the bridge before the processor runs; defaults to the retired
    /// certification for any correlation the gate already answered.
    private var lastRecordedEndState: String = "alreadyRetired"

    func recordAdmissionForProcessor(endState: String) {
        lastRecordedEndState = endState
    }

    private func lastEndState(conversationID: UUID, incarnation: UUID) -> String {
        // A recorded "fenced" whose cleanup claim failed means the first
        // cleanup already completed (the slot was detached exactly once):
        // the truthful endState is alreadyRetired, never a second "fenced".
        lastRecordedEndState == "fenced" ? "alreadyRetired" : lastRecordedEndState
    }

    private func consumeEndCleanup(conversationID: UUID,
                                   incarnation: UUID) -> Bool {
        guard let current = session,
              current.conversationID == conversationID,
              current.incarnation == incarnation else { return false }
        // The slot is the cleanup subject; the synchronous gate already
        // flipped the fence. The claim is exactly-once per tuple through
        // the slot write below (the first consumer detaches the slot).
        return true
    }

    // MARK: - Host lifecycle hints (NEVER a discard path)

    /// `system.lifecycle` integration: rotation/background/inactive/lock/
    /// view-reconstruction PRESERVE the exact session, run and route and
    /// claim nothing about navigation. There is no code path from a hint to
    /// `end()` by design; TMP-NAV-DISCARD(negative).
    public func noteHostLifecycleHint(_ hint: TemporaryHostLifecycleHint)
        -> TemporaryLifecycleAck {
        guard let session else { return .noSession }
        return .preserved(conversationID: session.conversationID,
                          incarnation: session.incarnation)
    }

    // MARK: - Temporary launch (typed port into the REAL run service)

    /// Entry point for the host glue / run lane when a presentation targets
    /// the LIVE hosted conversation. Validates BEFORE calling the port:
    /// exact identity + current generation + closed invariants (no
    /// attachments/staging in temporary; goal mode refused without the
    /// intelligence store; the ceiling can only be intersected, never
    /// widened). The port's refusal is mapped honestly.
    ///
    /// Race honesty: if an end lands while the launch is suspended inside
    /// the port, a `launched` reply is cancelled immediately (the run's
    /// stores are closed, its appends fail closed, the run owner settles
    /// its own final writes and detaches its own tokens) and the reply
    /// becomes a typed `sessionDiscarded` — a late callback from a blocked
    /// async launch can never leave live owned work for a tombstoned
    /// session and can never touch a replacement session.
    public func temporaryLaunch(conversationID: UUID, incarnation: UUID,
                                correlation: String, receipt: String?,
                                goal: String, mode: String,
                                preferredModelID: UUID?,
                                attachmentCount: Int,
                                stagedAttachmentHandles: Int) async -> TemporaryLaunchReply {
        if components.gate.blocksOperations(conversationID: conversationID,
                                            incarnation: incarnation) {
            return .refused(TemporaryDomainError(.sessionDiscarded,
                                                 .tombstonedDiscarded))
        }
        guard let current = session,
              current.conversationID == conversationID,
              current.incarnation == incarnation else {
            return .refused(TemporaryDomainError(.sessionDiscarded,
                                                 .tombstonedDiscarded))
        }
        guard attachmentCount == 0, stagedAttachmentHandles == 0 else {
            // Attachments/preprocessing/import are permission-unavailable
            // in temporary chat: refused structurally, never silently
            // stripped, never staged into a durable draft.
            return .refused(TemporaryDomainError(.capabilityUnavailable,
                                                 .attachmentsUnavailableInTemporary))
        }
        guard mode != "goal" else {
            // Goal mode needs the intelligence store; the temporary bundle
            // carries none (RAM-only invariant).
            return .refused(TemporaryDomainError(.capabilityUnavailable,
                                                 .goalModeUnsupportedStore))
        }
        let request = TemporaryLaunchRequest(
            conversationID: conversationID,
            incarnation: incarnation,
            epoch: current.epoch,
            correlation: correlation,
            receipt: receipt,
            goal: goal,
            mode: mode,
            preferredModelID: preferredModelID ?? current.preferredModelID,
            frozenToolCeiling: current.ceiling,
            stores: current.stores)
        let reply = await components.runPort.launchTemporary(request)
        switch reply {
        case .launched(let runID):
            guard self.session?.incarnation == incarnation else {
                // Tombstoned across the await: cancel the just-launched
                // owned run explicitly (the service's own unstructured work
                // closes; token detach stays with the run owner at its real
                // final writes) and report the discard honestly.
                await components.runPort.cancelTemporaryRun(
                    conversationID: conversationID, incarnation: incarnation,
                    runID: runID, epoch: current.epoch)
                return .refused(TemporaryDomainError(.sessionDiscarded,
                                                    .tombstonedDiscarded))
            }
            self.session?.ownedRunIDs.insert(runID)
            return reply
        case .refused:
            return reply
        }
    }

    /// The run lane reports a REAL run it re-owned over this exact session
    /// (the `run.retry` path, which reuses the same run id and therefore
    /// cannot pass through `temporaryLaunch`). Status/end-cancel ledger only;
    /// RB1 tokens stay with the run owner.
    public func noteTemporaryRunStarted(conversationID: UUID,
                                        incarnation: UUID,
                                        runID: UUID) {
        guard var current = session,
              current.conversationID == conversationID,
              current.incarnation == incarnation else { return }
        current.ownedRunIDs.insert(runID)
        session = current
    }

    /// The run lane reports a temporary run's REAL terminal here so the
    /// session's owned-run set reflects truth (used by status only; the
    /// RB1 tokens belong to the run owner — detach there, never here).
    public func noteTemporaryRunRetired(conversationID: UUID,
                                        incarnation: UUID, runID: UUID) {
        guard var current = session,
              current.conversationID == conversationID,
              current.incarnation == incarnation else { return }
        current.ownedRunIDs.remove(runID)
        session = current
    }

    // MARK: - temp.keep (conversationLifecycle, atomic promotion)

    /// One user/host-authorized Keep of the CURRENT incarnation.
    /// Idempotency (native :2347-2411): a second in-flight Keep is refused
    /// `duplicateInFlight{keepAlreadyInFlight}` — never a second writer; a
    /// repeat Keep after a committed receipt returns the durable id with
    /// `keep:"alreadyCommitted"` and performs NO second database work; only
    /// the operation's own completion clears its marker.
    public func keep(conversationID: UUID, incarnation: UUID,
                     idempotencyKey: UUID, receipt: String?,
                     correlation: String) async -> TemporaryDomainReply {
        // TMP-NAV-2 late-Keep admission: an actually-discarded tuple is
        // refused synchronously (the actor hop still re-checks; the
        // durable authority is the commit-boundary fence below).
        if components.gate.blocksOperations(conversationID: conversationID,
                                            incarnation: incarnation) {
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.sessionDiscarded, .tombstonedDiscarded)))
        }
        // ---- Synchronous gate: identity, state, no second writer. ----
        if let current = session,
           current.conversationID == conversationID,
           current.incarnation == incarnation,
           case .inFlight = current.promotion {
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.duplicateInFlight, .keepAlreadyInFlight)))
        }
        // Repeat Keep after success (the session slot is gone): surface the
        // durable receipt once more; a stale expectation can never adopt a
        // different promoted conversation (native :2369-2388).
        if session == nil {
            guard let promoted = lastPromoted,
                  promoted.hostedConversationID == conversationID,
                  promoted.incarnation == incarnation else {
                return TemporaryDomainReply(.rejected(
                    TemporaryDomainError(.notFound, .sessionAbsent)))
            }
            // Prove the durable row really exists before claiming success.
            do {
                guard try await components.durableConversations
                    .conversation(id: promoted.durableConversationID) != nil else {
                    return TemporaryDomainReply(.rejected(
                        TemporaryDomainError(.internalError, .internal)))
                }
            } catch {
                return TemporaryDomainReply(.rejected(
                    TemporaryDomainError(.persistenceUnavailable, .storeReadFailed)))
            }
            return TemporaryDomainReply(.mutationAccepted(
                detail: [
                    "keep": "alreadyCommitted",
                    "conversationID": promoted.durableConversationID.uuidString,
                ],
                value: .object([
                    "keep": .string("alreadyCommitted"),
                    "conversationID": .string(promoted.durableConversationID.uuidString),
                ])))
        }
        guard let current = session else {
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.notFound, .sessionAbsent)))
        }
        guard current.conversationID == conversationID else {
            // Foreign route: a stale expectation can never adopt a
            // different session's Keep.
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.notFound, .sessionNotCurrent)))
        }
        guard current.incarnation == incarnation else {
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.staleRevision, .incarnationMismatch)))
        }
        guard !current.fence.isFlipped else {
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.sessionDiscarded, .tombstonedDiscarded)))
        }

        // Attach the REAL RB1 owned-work entry BEFORE the durable write
        // starts. Refusal is conservative: no effect, no promotion, zero
        // durable rows.
        let workToken: RuntimeOwnedWorkToken
        switch RuntimeOwnedWorkRegistry.shared.attach(
            epoch: components.epoch, kind: .conversation,
            ownerID: conversationID.uuidString) {
        case .attached(let token):
            workToken = token
        case .rejected:
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.invalidState, .generationRetired)))
        case .invalidIdentity:
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.internalError, .internal)))
        }

        session?.promotion = .inFlight(idempotencyKey: idempotencyKey)
        session?.keepCorrelation = correlation
        defer {
            // Only THIS operation clears ITS marker.
            if session?.keepCorrelation == correlation {
                session?.keepCorrelation = nil
            }
            RuntimeOwnedWorkRegistry.shared.detach(workToken) // real completion/final failure ONLY (this function returns after all durable truth is recorded; never on timeout)
        }
        return await performKeep(idempotencyKey: idempotencyKey,
                                 receipt: receipt,
                                 workToken: workToken)
    }

    /// The promotion attempt (native `performKeep` semantics + commit
    /// fence). Resume-safe: after a post-commit tail failure the frozen
    /// context stays pinned and the next Keep resumes from the failed step.
    private func performKeep(idempotencyKey: UUID, receipt: String?,
                             workToken: RuntimeOwnedWorkToken) async -> TemporaryDomainReply {
        guard let current = session else {
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.notFound, .sessionAbsent)))
        }
        let conversationID = current.conversationID
        let incarnation = current.incarnation

        // ---- Frozen watermark snapshot (begin across ALL stores). ----
        let context: PromotionAttemptContext
        if let pinned = current.attempt,
           pinned.sessionID == conversationID,
           pinned.incarnation == incarnation {
            context = pinned            // RESUME: never re-begin, never
                                        // re-race stream appends.
        } else {
            do {
                let conversationSnapshot = try await current.stores.conversations.beginPromotion()
                let runSnapshot = try await current.stores.runs.beginPromotion()
                let inputSnapshot = try await current.stores.runningInputs.beginPromotion()
                var saved = conversationSnapshot.conversation
                saved.purpose = .ordinary
                if saved.title.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty {
                    // Local, instant, content-derived promotion title
                    // (first user message; the ordinary auto-title flow may
                    // replace it later — the durable autoPending predicate is
                    // the final guard, a manual rename is never overwritten).
                    saved.title = Self.promotedTitle(messages: conversationSnapshot.messages)
                }
                let fresh = PromotionAttemptContext(
                    sessionID: conversationID,
                    incarnation: incarnation,
                    idempotencyKey: idempotencyKey,
                    saved: saved,
                    conversationSnapshot: conversationSnapshot,
                    runSnapshot: runSnapshot,
                    inputSnapshot: inputSnapshot,
                    provenance: current.provenance)
                session?.attempt = fresh
                context = fresh
            } catch {
                // A begin failure on a partially begun set is aborted as a
                // whole (stores are still `.active`/consistent; nothing
                // durable happened).
                await current.stores.conversations.abortPromotion()
                await current.stores.runs.abortPromotion()
                await current.stores.runningInputs.abortPromotion()
                if session?.incarnation == incarnation { session?.promotion = .idle }
                return TemporaryDomainReply(.rejected(
                    TemporaryDomainError(.invalidState, .storeWriteFailed)))
            }
        }

        // ---- ONE original promoter transaction, under the fence. ----
        // Staged pre-dispatch seam (deterministic; production nil): a real
        // end landing here flips the fence while the commit is still
        // blocked — the early inside-transaction check refuses everything.
        await testHooks.afterFreezeBeforeCommit?()
        let snapshot = ConversationPromoter.Snapshot(
            conversation: context.saved,
            messages: context.conversationSnapshot.messages,
            attachments: context.conversationSnapshot.attachments,
            runs: context.runSnapshot.runs,
            events: context.runSnapshot.runs
                .flatMap { context.runSnapshot.events[$0.id, default: []] },
            usage: context.runSnapshot.runs
                .flatMap { context.runSnapshot.usage[$0.id, default: []] },
            errors: context.runSnapshot.runs
                .flatMap { context.runSnapshot.errors[$0.id, default: []] },
            inputs: context.inputSnapshot)
        do {
            // The additive overlay hook: the fence is consulted INSIDE the
            // writer transaction (before any write and again immediately
            // before the commit returns). See original-overlay/OVERLAY-
            // DEFECT.md — this is the ONLY supported authoritative commit
            // fence under concurrent end; the published original alone
            // offers none.
            try await promoter.promote(snapshot, commitFence: current.fence)
        } catch is PromotionCommitRefused {
            // Fence refused the COMMIT: zero durable rows. The session was
            // (or is being) authoritatively ended; the RAM buffers belong to
            // a destroyed session — never resurrect it for retry.
            await abortCommittedSide(current)
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.sessionDiscarded, .promotionRefusedByFence)))
        } catch {
            // Pre-commit integrity/SQL failure: the transaction rolled back
            // to zero durable rows (no compensating delete exists or is
            // needed). If we are still the current owner and the fence is
            // open, abort to `.idle` with RAM fully intact and retryable;
            // a replaced/tombstoned session gets no state mutations.
            let stillOwner = session?.incarnation == incarnation
            if stillOwner, !current.fence.isFlipped {
                await current.stores.conversations.abortPromotion()
                await current.stores.runs.abortPromotion()
                await current.stores.runningInputs.abortPromotion()
                session?.promotion = .idle
                session?.attempt = nil
                return TemporaryDomainReply(.rejected(
                    TemporaryDomainError(.persistenceUnavailable, .promoterCommitFailed)))
            }
            await abortCommittedSide(current)
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.sessionDiscarded, .tombstonedDiscarded)))
        }

        // The durable commit happened: the prepared stage may now honestly
        // name the durable identity (never before a real atomic commit).
        if let receipt {
            components.effects.append(receipt: receipt, kind: .prepared,
                                      detail: ["conversationID": conversationID.uuidString])
        }
        await testHooks.afterCommit?()

        // ---- Forward the tail through the ORIGINAL gateways. ----
        do {
            let hook = testHooks.beforeGatewayStep
            if !(await current.stores.conversations.isForwarded) {
                try await hook?(1)
                try await current.stores.conversations.completePromotion(
                    durable: components.durableConversations)
            }
            if !(await current.stores.runs.isForwarded) {
                try await hook?(2)
                try await current.stores.runs.completePromotion(
                    durable: components.durableRuns)
            }
            if !(await current.stores.runningInputs.isForwarded) {
                try await hook?(3)
                try await current.stores.runningInputs.completePromotion(
                    durable: components.durableRunningInputs)
            }
        } catch {
            // POST-COMMIT tail failure: the committed conversation is
            // ordinary truth (durable id published honestly); the frozen
            // context stays pinned so the NEXT Keep on the SAME live
            // incarnation resumes the failed gateway step exactly once.
            // Never a false "atomic rollback" claim, never a re-begin.
            let (conversationForwarded, runForwarded, _) =
                await current.stores.gatewayStates()
            let stillOwner = session?.incarnation == incarnation
            if !conversationForwarded && !runForwarded {
                // The failure struck the FIRST gateway (nothing forwarded):
                // the committed rows are still truth, but the whole gateway
                // set is retryable as a unit — keep the pinned context for
                // the resume and restore the retryable promotion marker for
                // the SAME identity only.
                if stillOwner, !current.fence.isFlipped {
                    session?.promotion = .tailPending(durable: conversationID)
                    return TemporaryDomainReply(.rejected(
                        TemporaryDomainError(.persistenceUnavailable,
                                             .tailForwardPending)))
                }
                return TemporaryDomainReply(.rejected(
                    TemporaryDomainError(.sessionDiscarded, .tombstonedDiscarded)))
            }
            if stillOwner, !current.fence.isFlipped {
                session?.promotion = .tailPending(durable: conversationID)
                return TemporaryDomainReply(.rejected(
                    TemporaryDomainError(.persistenceUnavailable,
                                         .tailForwardPending)))
            }
            // Destroyed/replaced owner: the committed rows + already
            // forwarded steps stay truth; the abandoned tail is refused to
            // this stale operation.
            return TemporaryDomainReply(.rejected(
                TemporaryDomainError(.sessionDiscarded, .tombstonedDiscarded)))
        }

        // ---- Success. The COMMIT is a fact (the promoter awaited the real
        // writer). Record the durable receipt idempotently even when a
        // concurrent end already tombstoned the slot: a Keep whose commit
        // truly landed first stays ordinary truth — the receipt below is
        // the same durable conversation the end's discard never touches.
        let stillOwner = session?.incarnation == incarnation
        lastPromoted = PromotedReceipt(
            hostedConversationID: conversationID,
            incarnation: incarnation,
            durableConversationID: conversationID)
        if stillOwner {
            session = nil                       // the RAM session's job is
                                                // done; it never outlives a
                                                // committed Keep
            await components.hostSurface?.surfacePromoted(
                conversationID: conversationID,
                incarnation: incarnation,
                durableConversationID: conversationID)
        }
        // Final committed Keep promotes route ownership ONCE: the promoter
        // created/carried the canonical private-task workspace inside the
        // SAME transaction (`SQLiteWorkspaceStore.ensureWorkspace` — the
        // ORIGINAL explicit route/ownership semantics, never a silent first-
        // workspace guess), and this receipt is the only adoption marker.
        // Late callbacks from the old session can no longer resolve
        // authority (`authority(...)` returns nil for the cleared slot).
        return TemporaryDomainReply(.mutationAccepted(
            detail: [
                "keep": "committed",
                "conversationID": conversationID.uuidString,
                // Frozen provenance travels as identifiers/flags ONLY — the
                // post-Keep surfaces must keep temporaryAtStart/frozenTemporaryRun
                // true for these historical rows (no retroactive learning).
                "temporaryAtStart": "true",
                "frozenTemporaryRun": "true",
            ],
            value: .object([
                "keep": .string("committed"),
                "conversationID": .string(conversationID.uuidString),
                "temporaryAtStart": .string("true"),
                "frozenTemporaryRun": .string("true"),
            ])))
    }

    /// Abort bookkeeping for an operation whose session is no longer ours:
    /// flip the promotion markers on the DESTROYED snapshot only through the
    /// original gateway semantics (abort on a closed store is a documented
    /// no-op; the buffers stay closed and refuse late appends).
    private func abortCommittedSide(_ current: Session) async {
        await current.stores.conversations.abortPromotion()
        await current.stores.runs.abortPromotion()
        await current.stores.runningInputs.abortPromotion()
    }

    // MARK: - Generation retirement (root shutdown: DISCARD, never auto-Keep)

    /// Bound by Main into the shutdown path before the drain loop (same
    /// reviewed shape as `RunDomainFacade.beginGenerationRetirement`). It
    /// tombstones the live session — discard, NEVER an implicit Keep:
    /// nothing may persist temporary content without the explicit user/
    /// host-authorized temp.keep on the current incarnation. An in-flight
    /// Keep job (a separate mailbox entry) settles truthfully on its own:
    /// committed rows survive, fence-refused/aborted ones leave zero durable
    /// rows. Its attached token keeps the global drain gate honest until the
    /// real final writes are done (no timeout detach).
    public func beginGenerationRetirement() async {
        guard let current = session else { return }
        current.fence.flip()
        session = nil
        lastPromoted = nil
        await current.stores.closeAll()
        for runID in current.ownedRunIDs {
            await components.runPort.cancelTemporaryRun(
                conversationID: current.conversationID,
                incarnation: current.incarnation,
                runID: runID,
                epoch: current.epoch)
        }
        await components.hostSurface?.surfaceDiscarded(
            conversationID: current.conversationID,
            incarnation: current.incarnation)
    }

    // MARK: - Promotion title (native :2440-2450 behavior)

    static func promotedTitle(messages: [PersistedMessage]) -> String {
        guard let first = messages.first(where: { $0.role == "user" }) else {
            return ""
        }
        let source = first.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return "" }
        let title = String(source.prefix(40))
        return title.count < source.count ? title + "…" : title
    }
}
