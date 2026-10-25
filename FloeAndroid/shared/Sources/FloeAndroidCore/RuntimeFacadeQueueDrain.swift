// SPDX-License-Identifier: MPL-2.0
//
// G04R2 queue-input repair — the MISSING Android counterpart of the
// ORIGINAL iOS queued-input consumption lane
// (`FloeApp/Remote/ConversationCenter.swift:4764 launchNextQueuedInput`,
// called at :5456 from the run-task settlement on `completed`/`failed` and
// at :4741 from the steer-target-ended fallback).
//
// Why this file exists (proven by callsite, device evidence
// c03-queue-edit-cancel.xml + entry/C03_QUEUE_EDIT_PARTIAL.json): the
// durable `SQLiteRunningInputStore.claimNextQueued` existed but had ZERO
// production callers in the Android tree. A queued row therefore stayed
// `queued` forever — the projection honestly rendered "Waits for the
// current run to finish" even with `isRunning == false`, and the row could
// never become a run. Enqueue/edit/remove/reorder/steer were all wired;
// only the terminal consumption was absent.
//
// Contract (identical to the iOS lane and to the existing owned-maintenance
// precedents in this actor — `dispatchGoalReview`, `dispatchIntelligenceFeed`):
//
//   * Dispatch gate: the REAL terminal of an ORDINARY run that THIS
//     generation settled (`retire(feedTerminal: true)` — completed AND
//     failed, matching iOS `terminalState == "completed" || "failed"`).
//     Temporary identities never enter (their RAM queue belongs to the
//     run's own ephemeral store). Abandoned-launch / boot-reconcile
//     retirements pass `feedTerminal: false` and never drain.
//   * REAL lease: an exact `.conversation` RuntimeOwnedWork token attaches
//     BEFORE the dispatching step returns and is released ONLY when the
//     lane really finished — the per-conversation delete drain and root
//     shutdown wait it (feed evidence), never a timer.
//   * SINGLE FLIGHT + COALESCED WAKEUP (Main review 2026-10-25, C05
//     repair): the registry mints a fresh token per attach and does NOT
//     dedupe by owner, so single flight is actor state
//     (`queueDrainActive`). A real terminal that arrives while the lane
//     is mid-await (a very fast launched run can settle inside
//     `start`/`markConsumed`) coalesces into `queueDrainRecheck`. After a
//     SUCCESSFUL launch+receipt the lane consumes the flag, re-proves
//     fences and sibling liveness and claims the next row under the SAME
//     lease. EVERY other exit (refusal-restored, live-sibling deferral,
//     store failure, no rows, bound) HONORS a parked flag by re-dispatching
//     ONE bounded follow-up lane through the original dispatch gate —
//     silently dropping it (the C05 defect,
//     the captured queued-message retirement failure: the fast loopback
//     follow-up's real terminal coalesced while the lane was mid-await,
//     the lane then restored its head row and exited) stranded the queue
//     forever, because the parked terminal HAD been the conversation's
//     last run and no later terminal existed to re-dispatch. A
//     re-dispatch never parks a flag itself (only a real terminal arriving
//     while a lane is ACTIVE does), so a persistently refusing head row
//     costs at most ONE extra honest attempt per parked real terminal —
//     bounded, no spin, no duplicate launch, no start during a live
//     sibling.
//   * Sibling-live-run guard: iOS refuses while ANY run service for the
//     conversation is non-terminal (ConversationCenter:4765); here a
//     non-empty `owners(conversationID:)` means a live sibling. C05
//     repair: the guard is re-proved TWICE — synchronously at dispatch
//     AND immediately before `start`, after every claim/route await. A
//     user send that lands while the lane is mid-await previously let the
//     lane launch a second ordinary run under the live sibling (the exact
//     device interleaving: the queued row's user turn was persisted
//     BETWEEN the follow-up run's user turn and its final assistant
//     message). A deferral restores the row with NO durable effect (the
//     launch never happened) and the sibling's own real terminal
//     re-dispatches.
//   * Fences re-proved after EVERY await (retirement fence, global
//     admission fence, per-conversation delete guard, task cancellation):
//     no stale-epoch start, no start past a deletion.
//   * Claim exclusivity: `claimNextQueued` is the durable atomic
//     queued→promoting CAS (store SQL also excludes `browserHandoff`
//     rows — the G04 handoff notice is never launched as a user turn).
//     From the claim on, EVERY refusal path restores the row to `queued`
//     (`restoreQueued`): an explicit real refusal keeps the row visibly
//     queued with its original body — never a fake launch, never a
//     silently stranded or dropped row. A crash between claim and receipt
//     is recovered by the ORIGINAL `recoverTransientInputs` (promoting
//     without `consumed_run_id` → queued at next start).
//   * FULL row ownership (Main directive — no text-only shortcut):
//     - ATTACHMENTS: the row's resolved durable `AttachmentRef`s launch
//       through the trusted INTERNAL `preResolvedAttachments` seam of the
//       ORIGINAL `start(query:)` pipeline (same atomic prepare binding,
//       same image/capability admission, same C1 transaction as staged
//       lease refs; provenance re-proved there with the ORIGINAL storage
//       rules and conversation binding). The queue-time resolve already
//       consumed the staging surface, so the row — not a handle — is the
//       durable owner; the claim CAS is this launch's exclusive right.
//     - MODEL: iOS `providerAndModel` parity (ConversationCenter:7260) —
//       an EXPLICIT row `selectedModelID` resolves through the enabled
//       model+provider pair or the lane REFUSES (never a silent default
//       fallback); only a NIL selection falls back to the persisted
//       DEFAULT AGENT model (never a first-provider guess, never local).
//       Final proof is the ORIGINAL `RunModelAssembly.resolveSelected`
//       admission (enabled rows, provider match, wire protocol, no local
//       inference).
//     - MODE: the row's persisted `executionMode` (run.queue now carries
//       the composer's REAL mode) maps through the App's own vocabulary
//       (ConversationProjections.runLaunchMode:2202 — AGENT and CHAT both
//       travel the chat spelling; plan/goal map to themselves). An unknown
//       mode is an explicit refusal, never a guessed default.
//   * Launch: the SAME real `start(query:)` admission pipeline every
//     ordinary launch uses (guard/fence admission, per-conversation
//     reservation, C0/C1 atomic prepare, credential resolution) through
//     the internal seam already used by plan-commit, goal continuation and
//     temporary promotion. The consumed receipt is the ORIGINAL
//     `markConsumed(id:runID:)` exactly-once durable proof; a
//     receipt-write failure restores the row (iOS parity:
//     `try await markConsumed` catch → `restoreQueued`).
//   * COMMITTED-REFUSAL retirement (C05 repair): `start` refuses AFTER the
//     atomic prepare in the `cancelledBeforeStart` and
//     `serviceAssemblyFailed` landings, which keep the row's exact user
//     turn durably persisted and mark the committed run failed. Restoring
//     the row in that state strands a row whose content is already handled
//     and re-persists the SAME user turn on the next drain (duplicate
//     user persist — the observed persisted-as-user-but-row-queued device
//     state). The drain therefore passes `queuedInputProofID` and, when a
//     refusal carries the committed-run proof, retires the row against
//     that REAL abandoned run with `markConsumed` (the durable failed run
//     row is the honest receipt — never a fake success, never a dropped
//     row). Only a refusal with NO committed proof (provable C0 no-effect)
//     restores the row to `queued`.

import Foundation
import FloeCore
import FloeModels
import FloePersistence

// MARK: - Queue-settle publication vocabulary (C09 QREV-01/03)

/// The drain lane's OWN exit classification — lifecycle metadata carried on
/// the existing stateless `queueSettled` notice fact so the host observer
/// knows from the durable fact itself whether another fact is guaranteed
/// later. It is NEVER queue authority: the authoritative conversation/queue
/// pages remain the truth, and this vocabulary renders nothing.
enum QueueSettleLaneExit: String {
    case consumed    // a row was consumed under its real receipt this lane
    case refused     // a claimed row was restored (route/mode/receipt refusal)
    case rested      // nothing claimable, or the bound was exhausted
    case deferred    // a live sibling / launch-boundary deferral skipped work
    case failed      // store throw or a closed fence ended the lane
}

/// Typed outcome of one settle publication attempt (internal Swift only;
/// never a wire member, never a fabricated run state, never a fake ack).
enum QueueSettlePublication: Equatable {
    case published              // fact appended AND verified materialized
    case fenced                 // fences closed — no owned write after retirement
    case appendFailed           // journal append threw; degraded signal set
    case windowUnmaterialized   // fact durable but window unverifiable
    case noAnchor               // nil-anchor dispatch (byte-identical baseline path)
}

/// Honesty-floor counters, asserted by the native regressions. Counters
/// alone are NOT the recovery path (Main rejected that design): recovery is
/// the degraded-window → existing `resyncRequired` → authoritative host
/// reconcile. These only prove a publication is never silently swallowed.
/// Explicitly Sendable: the whole snapshot crosses the actor boundary into
/// regression assertions.
struct QueueSettleStats: Sendable {
    var published = 0
    var appendFailed = 0
    var windowUnmaterialized = 0
    var fencedSkipped = 0
    var siblingPublishDeferred = 0
}

// MARK: - Dispatch + real lease (mirrors dispatchGoalReview exactly)

extension FacadeRunDomain {

    /// The terminal-settlement dispatch gate. Synchronous lease attach
    /// BEFORE the first await of the lane (RUN-S3 semantics): the delete
    /// drain and root shutdown observe real owned work, never a window.
    ///
    /// C09 QREV-01: `anchorRunID` is the REAL retired terminal whose
    /// settlement dispatched this duty. Only a non-nil anchor activates the
    /// settle publication; every nil-anchor dispatch (historical callers and
    /// the existing direct-dispatch tests) behaves byte-identically to the
    /// frozen baseline. The publication rides the STILL-HELD lane lease (see
    /// `exitQueueDrain`), never a detached background write.
    func dispatchQueuedInputDrain(conversationID: UUID,
                                  bundle: RunPersistenceBundle,
                                  anchorRunID: UUID? = nil) {
        guard bundle.identity == .ordinary,
              !retirementFenced, globalFence == nil,
              deleteGuards[conversationID] == nil else { return }
        // A live sibling run owns the queue: its own real terminal drains
        // (strict order, one lane per conversation).
        guard owners(conversationID: conversationID).isEmpty else {
            // With an anchor this skip is a REAL observation boundary the
            // host watch needs closed causally: publish the skip fact under
            // a dedicated short lease (owned IO, exact-token detach last)
            // so the watch on THIS anchor reconciles and its session page
            // discovers the live sibling (resumeLiveRuns pumps it; a later
            // terminal re-arms). A nil anchor keeps the frozen baseline
            // bare-return behavior.
            if let anchorRunID {
                publishSiblingSkipSettle(conversationID: conversationID,
                                         bundle: bundle,
                                         anchorRunID: anchorRunID)
            }
            return
        }
        // SINGLE FLIGHT: the lane is actor state, not the registry (attach
        // does not dedupe by ownerID). A terminal arriving while the lane
        // is mid-await coalesces into the pending-wakeup flag; the lane
        // consumes it after its current launch settles — the lost-wakeup
        // boundary is closed without a second concurrent lane.
        if queueDrainActive.contains(conversationID) {
            queueDrainRecheck.insert(conversationID)
            if let anchorRunID {
                // Park records the parking terminal's duty anchor: the
                // honoring re-dispatch publishes where the host's CURRENT
                // watch reads (the parked terminal is the newest durable
                // terminal, so its journal is where its own watch's fact
                // must land).
                queueDrainDuties[conversationID] = anchorRunID
            }
            return
        }
        let ownerID = conversationID.uuidString + ":queue-drain"
        switch RuntimeOwnedWorkRegistry.shared.attach(epoch: epoch, kind: .conversation,
                                                      ownerID: ownerID) {
        case .attached(let token):
            // A direct attach SUBSUMES a stale duty: this lane's own chain
            // (its exits publish, the tail honors new parks) covers the
            // conversation from now on.
            if anchorRunID != nil {
                queueDrainDuties[conversationID] = nil
            }
            queueDrainActive.insert(conversationID)
            queueDrainLeases[conversationID, default: [:]][token.receipt] = token
            recordFeedEvidence(conversationID: conversationID, token: token)
            Task { [weak self] in
                guard let self else { return }
                await self.drainQueuedInput(conversationID: conversationID,
                                            bundle: bundle,
                                            token: token,
                                            anchorRunID: anchorRunID)
            }
        case .rejected, .invalidIdentity:
            // Lease saturation (or a foreign generation): honest skip — the
            // row stays durably queued and the next real terminal re-drains.
            // R1 residual (Main lifecycle correction): NO duty dictionary
            // write here — there is no active lane or park that could ever
            // consume it, so a deferred-only entry would accumulate without
            // causal function. The counter is the honest record; no IO is
            // invented after a rejected lease. The host watch closes through
            // its existing lifecycle (replacement by the next terminal arm,
            // navigation, retire or stop) and the next REAL chain publishes
            // and self-heals.
            feedStats.saturatedSkipped += 1
        }
    }

    private func releaseQueueDrainLease(conversationID: UUID,
                                        token: RuntimeOwnedWorkToken) {
        RuntimeOwnedWorkRegistry.shared.detach(token)
        queueDrainLeases[conversationID]?.removeValue(forKey: token.receipt)
        if queueDrainLeases[conversationID]?.isEmpty == true {
            queueDrainLeases[conversationID] = nil
        }
    }

    /// Lane exit (C09 QREV-01): the settle fact publishes FIRST, inside the
    /// still-held registry lease with the lane still ACTIVE, so the delete
    /// drain and root shutdown (registry `waitForDrain` on `count(for:)`)
    /// observe real owned work across ALL publication IO — a terminal
    /// arriving during the publish await still finds the lane active and
    /// coalesces into `queueDrainRecheck` (single-flight untouched). Then the
    /// ORIGINAL synchronous tail runs byte-for-byte: consume the parked flag,
    /// drop the duty anchor, clear the active flag, release the EXACT token
    /// LAST, and re-dispatch one bounded follow-up lane only after the active
    /// flag and lease are gone. No await after the detach. The re-dispatch
    /// re-validates identity, fences, sibling liveness and single flight
    /// itself; duty inheritance publishes the follow-up chain where the
    /// host's CURRENT watch reads (§2 park record).
    private func exitQueueDrain(conversationID: UUID,
                                token: RuntimeOwnedWorkToken,
                                bundle: RunPersistenceBundle,
                                anchorRunID: UUID?,
                                lane: QueueSettleLaneExit) async {
        // Truthful at construction: only a park landing inside the publish
        // await can falsify it, and the tail still honors that park while
        // the duty anchor carries the follow-up's publication target
        // (stale-"closed" neutralization: contract §6 P6).
        let chainOpen = queueDrainRecheck.contains(conversationID)
        _ = await publishQueueSettled(conversationID: conversationID,
                                      bundle: bundle,
                                      anchorRunID: anchorRunID,
                                      lane: lane,
                                      chainOpen: chainOpen)
        // Synchronous tail — NO await between the state clears, the exact-
        // token detach and the (post-detach) re-dispatch.
        let parked = queueDrainRecheck.remove(conversationID) != nil
        let dutyAnchor = queueDrainDuties.removeValue(forKey: conversationID)
        queueDrainActive.remove(conversationID)
        releaseQueueDrainLease(conversationID: conversationID, token: token)
        if parked {
            dispatchQueuedInputDrain(conversationID: conversationID,
                                     bundle: bundle,
                                     anchorRunID: dutyAnchor ?? anchorRunID)
        }
    }

    // MARK: - Settle publication (QREV-01 owned IO / QREV-03 typed results)

    /// Publishes the stateless `queueSettled` invalidation fact onto the
    /// anchor run's OWN durable journal and materializes it into the shared
    /// event pump window, ALL under the still-held lane lease. Fences are
    /// re-proved after EVERY await: no silent write after root retirement.
    /// Rows/receipts are untouched by any publication failure (consumption
    /// committed in separate earlier transactions): a failed append or an
    /// unverifiable window drives the CURRENT host observer through the
    /// EXISTING `resyncRequired` durable member (`markSettlePublication
    /// Degraded`), never a fabricated status, never a swallowed write.
    ///
    /// MAIN_ADDENDUM F: no append RETRY. An auxiliary append throw is not
    /// assumed to prove non-commit (that guarantee belongs to the store);
    /// the fact degrades IMMEDIATELY and the host reconciles from real
    /// pages. Business run creation/consumption/user turn are NEVER retried
    /// here.
    ///
    /// Materialization is PROGRESS-DRIVEN, not attempt-counted: each refresh
    /// returns the post-merge watermark and the loop continues while it
    /// strictly advances toward the committed sequence (a valid multi-page
    /// backlog pages through deterministically); the page bound (64 pages =
    /// 12,800 events) is generous headroom over any real terminal-tail
    /// backlog, and exhaustion degrades honestly into the same host resync
    /// path — never a timer, never a fixed "two attempts = failure" guess.
    private func publishQueueSettled(conversationID: UUID,
                                     bundle: RunPersistenceBundle,
                                     anchorRunID: UUID?,
                                     lane: QueueSettleLaneExit,
                                     chainOpen: Bool) async -> QueueSettlePublication {
        guard let anchorRunID else { return .noAnchor }
        guard drainFencesOpen(conversationID: conversationID) else {
            queueSettleStats.fencedSkipped += 1
            return .fenced
        }
        let payload = Self.jsonString([
            "reason": Self.queueSettleReason,
            "lane": lane.rawValue,
            "chain": chainOpen ? "open" : "closed",
        ])
        let record: RunEventRecord
        do {
            record = try await bundle.runs.appendEvent(runID: anchorRunID,
                                                       kind: .notice,
                                                       payloadJSON: payload)
        } catch {
            guard drainFencesOpen(conversationID: conversationID) else {
                queueSettleStats.fencedSkipped += 1
                return .fenced
            }
            queueSettleStats.appendFailed += 1
            components.events.markSettlePublicationDegraded(
                runID: anchorRunID, expectedSequence: nil)
            return .appendFailed
        }
        var lastWatermark = -1
        var readFailures = 0
        for _ in 0..<Self.queueSettleMaterializationPageBound {
            guard drainFencesOpen(conversationID: conversationID) else {
                queueSettleStats.fencedSkipped += 1
                // The fact IS durable; the window refresh is skipped because
                // the root is retiring. The consumer's own lifecycle closes.
                return .fenced
            }
            switch await components.events.refreshDurableWindow(
                runID: anchorRunID, store: bundle.runs) {
            case .refreshed(let watermark):
                if watermark >= record.sequence {
                    components.events.clearSettlePublicationDegraded(runID: anchorRunID)
                    queueSettleStats.published += 1
                    return .published
                }
                if watermark > lastWatermark {
                    lastWatermark = watermark
                    continue          // real backlog progress — keep paging
                }
                readFailures += 1      // committed frame missing with NO progress
                if readFailures < 2 { continue }
            case .failedRead:
                readFailures += 1
                if readFailures < 2 { continue }  // transient-tolerant, bounded
            }
            queueSettleStats.windowUnmaterialized += 1
            components.events.markSettlePublicationDegraded(
                runID: anchorRunID, expectedSequence: record.sequence)
            return .windowUnmaterialized
        }
        queueSettleStats.windowUnmaterialized += 1
        components.events.markSettlePublicationDegraded(
            runID: anchorRunID, expectedSequence: record.sequence)
        return .windowUnmaterialized
    }

    /// QREV-01 sibling-skip publication: a dedicated SHORT lease wraps only
    /// the publication IO (attach → publish → exact-token detach last, no
    /// await after the detach). `recordFeedEvidence` makes the per-
    /// conversation delete drain wait this token too, so the skip fact is
    /// durable-or-typed-degraded before anything can retire underneath it.
    /// Registry saturation defers the duty honestly (R1): the next real
    /// chain publishes and the host watch is replaced by that terminal's arm.
    private func publishSiblingSkipSettle(conversationID: UUID,
                                          bundle: RunPersistenceBundle,
                                          anchorRunID: UUID) {
        let ownerID = conversationID.uuidString + ":queue-settle-skip"
        switch RuntimeOwnedWorkRegistry.shared.attach(epoch: epoch, kind: .conversation,
                                                      ownerID: ownerID) {
        case .attached(let token):
            queueDrainLeases[conversationID, default: [:]][token.receipt] = token
            recordFeedEvidence(conversationID: conversationID, token: token)
            Task { [weak self] in
                guard let self else {
                    // Domain gone with the generation: the registry's own
                    // generation teardown removes the leftover token.
                    _ = RuntimeOwnedWorkRegistry.shared.detach(token)
                    return
                }
                _ = await self.publishQueueSettled(conversationID: conversationID,
                                                   bundle: bundle,
                                                   anchorRunID: anchorRunID,
                                                   lane: .deferred,
                                                   chainOpen: true)
                await self.releaseQueueDrainLease(conversationID: conversationID,
                                                  token: token)
            }
        case .rejected, .invalidIdentity:
            // Main lifecycle correction: a rejected dedicated lease writes
            // NO duty entry (no consuming lane exists — deferred-only
            // entries would accumulate across conversations with no causal
            // function). The counter is the honest record; the host watch
            // ends through its existing lifecycle and the next real chain
            // publishes where that watch's replacement reads.
            queueSettleStats.siblingPublishDeferred += 1
        }
    }

    // MARK: - The lane (claim → launch → receipt; coalesced recheck loop)

    /// The lane body. `anchorRunID` is the dispatch's settle-publication
    /// anchor (nil keeps every exit publication-free, byte-identical to the
    /// frozen baseline behavior of the historical direct-dispatch tests);
    /// every real exit now routes through the async `exitQueueDrain`, whose
    /// honest `lane:` class labels WHY the lane ended.
    private func drainQueuedInput(conversationID: UUID,
                                  bundle: RunPersistenceBundle,
                                  token: RuntimeOwnedWorkToken,
                                  anchorRunID: UUID?) async {
        // Bounded by the durable queue bound: every iteration either
        // consumes one row (launch + receipt) or exits; refusals never
        // loop. 100 rows is the store's own maximumPendingPerConversation.
        for _ in 0..<SQLiteRunningInputStore.maximumPendingPerConversation {
            guard drainFencesOpen(conversationID: conversationID) else {
                await exitQueueDrain(conversationID: conversationID, token: token,
                                     bundle: bundle, anchorRunID: anchorRunID,
                                     lane: .failed)
                return
            }
            let claimed: PendingUserInput?
            do {
                claimed = try await bundle.runningInputs.claimNextQueued(
                    conversationID: conversationID)
            } catch {
                // Store failure: nothing claimed, nothing to restore. The
                // rows stay queued; the next real terminal re-drains.
                await exitQueueDrain(conversationID: conversationID, token: token,
                                     bundle: bundle, anchorRunID: anchorRunID,
                                     lane: .failed)
                return
            }
            guard let row = claimed else {
                await exitQueueDrain(conversationID: conversationID, token: token,
                                     bundle: bundle, anchorRunID: anchorRunID,
                                     lane: .rested)
                return
            }
            // From the claim on the row is `promoting`: EVERY refusal below
            // restores it to `queued` (original body/attachments/mode
            // byte-intact) and EXITS — a refused head row is never
            // re-looped into a spin.
            guard drainFencesOpen(conversationID: conversationID) else {
                await restoreQueuedRow(bundle: bundle, id: row.id)
                await exitQueueDrain(conversationID: conversationID, token: token,
                                     bundle: bundle, anchorRunID: anchorRunID,
                                     lane: .failed)
                return
            }
            guard let mode = Self.queuedLaunchMode(row.executionMode) else {
                // Unknown/internal execution mode: never launch what the
                // original vocabulary does not cover (browserHandoff rows
                // are already excluded by the claim SQL).
                await restoreQueuedRow(bundle: bundle, id: row.id)
                await exitQueueDrain(conversationID: conversationID, token: token,
                                     bundle: bundle, anchorRunID: anchorRunID,
                                     lane: .refused)
                return
            }
            guard let route = await queuedInputRoute(selectedModelID: row.selectedModelID) else {
                await restoreQueuedRow(bundle: bundle, id: row.id)
                await exitQueueDrain(conversationID: conversationID, token: token,
                                     bundle: bundle, anchorRunID: anchorRunID,
                                     lane: .refused)
                return
            }
            guard drainFencesOpen(conversationID: conversationID),
                  owners(conversationID: conversationID).isEmpty else {
                // C05 repair — the live-sibling guard must hold AT LAUNCH
                // time, not only at dispatch (iOS: every service terminal
                // before a drain launch). A deferral restores the row with
                // NO durable effect; the live sibling's own real terminal
                // re-dispatches (and any parked wakeup is honored below).
                await restoreQueuedRow(bundle: bundle, id: row.id)
                await exitQueueDrain(conversationID: conversationID, token: token,
                                     bundle: bundle, anchorRunID: anchorRunID,
                                     lane: .deferred)
                return
            }
            // The SAME real launch pipeline (admission, reservation,
            // atomic C0/C1 prepare, credential resolution) — internal
            // receipt-less start, exactly like the goal-continuation lane.
            // The row's resolved durable attachments ride the trusted
            // `preResolvedAttachments` seam (FULL ownership — the row is
            // never launched without its attachments and never stranded
            // because of them). No digest CAS is passed: the claim
            // transition is the row authority and the launch participates
            // in the shared per-conversation reservation (a lost race
            // refuses here and the row restores).
            let reply = await start(
                query: RunStartQuery(
                    conversationID: conversationID,
                    goal: row.content,
                    mode: mode,
                    providerID: route.provider.id,
                    modelID: route.model.id),
                conversationTitle: "",
                receipt: nil,
                conversationID: conversationID,
                bundleOverride: bundle,
                capturedLaunch: route,
                preResolvedAttachments: row.attachments,
                queuedInputProofID: row.id)
            var startedRunID: UUID?
            if case .mutationAccepted(let detail) = reply.outcome {
                startedRunID = UUID(uuidString: detail["runID"] ?? "")
            }
            guard let startedRunID else {
                // C05 repair — a refusal that carries the committed-run
                // proof refused AFTER the atomic prepare: the row's exact
                // text is ALREADY durably persisted as that abandoned
                // run's user turn (the durable failed run row is the
                // honest receipt). Retire against the committed run id
                // through the ORIGINAL exactly-once CAS; only a refusal
                // with NO proof (provable C0, no durable effect) restores
                // the row. A receipt-write failure restores honestly
                // (iOS parity) — the durable truth then shows both the
                // persisted turn and the re-queued row.
                if let committedRunID =
                    postCommitRefusedLaunches.removeValue(forKey: row.id) {
                    do {
                        try await bundle.runningInputs.markConsumed(
                            id: row.id, runID: committedRunID)
                    } catch {
                        await restoreQueuedRow(bundle: bundle, id: row.id)
                        await exitQueueDrain(conversationID: conversationID,
                                             token: token, bundle: bundle,
                                             anchorRunID: anchorRunID,
                                             lane: .refused)
                        return
                    }
                    await exitQueueDrain(conversationID: conversationID,
                                         token: token, bundle: bundle,
                                         anchorRunID: anchorRunID,
                                         lane: .consumed)
                    return
                }
                await restoreQueuedRow(bundle: bundle, id: row.id)
                await exitQueueDrain(conversationID: conversationID, token: token,
                                     bundle: bundle, anchorRunID: anchorRunID,
                                     lane: .refused)
                return
            }
            do {
                try await bundle.runningInputs.markConsumed(id: row.id,
                                                            runID: startedRunID)
            } catch {
                // Receipt-write failure after a real launch: restore (iOS
                // parity) — the durable truth then shows both the launched
                // user turn and the re-queued row; a later terminal drain
                // is bounded by the claim CAS and the visible queue.
                await restoreQueuedRow(bundle: bundle, id: row.id)
                await exitQueueDrain(conversationID: conversationID, token: token,
                                     bundle: bundle, anchorRunID: anchorRunID,
                                     lane: .refused)
                return
            }
            // One row consumed under its real receipt. COALESCED WAKEUP:
            // a very fast launched run can settle inside the awaits above
            // and find this lane busy — its terminal parked in the recheck
            // flag. Consume it and continue ONLY when no sibling run is
            // live anymore (the launched run already retired); otherwise
            // exit — the live sibling's own terminal dispatches a fresh
            // lane (this lane is no longer active by then, synchronously).
            if queueDrainRecheck.remove(conversationID) != nil,
               drainFencesOpen(conversationID: conversationID),
               owners(conversationID: conversationID).isEmpty {
                continue
            }
            await exitQueueDrain(conversationID: conversationID, token: token,
                                 bundle: bundle, anchorRunID: anchorRunID,
                                 lane: .consumed)
            return
        }
        // Queue bound exhausted (a pathological 100-row instant chain):
        // honest exit; the next real terminal re-drains.
        await exitQueueDrain(conversationID: conversationID, token: token,
                             bundle: bundle, anchorRunID: anchorRunID,
                             lane: .rested)
    }

    /// The fence re-proof used at every post-await boundary of the lane.
    private func drainFencesOpen(conversationID: UUID) -> Bool {
        !Task.isCancelled && !retirementFenced && globalFence == nil &&
            deleteGuards[conversationID] == nil
    }

    private func restoreQueuedRow(bundle: RunPersistenceBundle, id: UUID) async {
        try? await bundle.runningInputs.restoreQueued(id: id)
    }

    /// The App's own execution-mode → launch-mode vocabulary
    /// (ConversationProjections.runLaunchMode: AGENT and CHAT both travel
    /// the chat spelling; plan/goal map to themselves). Anything else is
    /// an explicit refusal — never a guessed mode.
    static func queuedLaunchMode(_ executionMode: String) -> RunLaunchMode? {
        switch executionMode {
        case "agent", "chat": return .chat
        case "plan": return .plan
        case "goal": return .goal
        default: return nil
        }
    }

    /// iOS `providerAndModel` parity (ConversationCenter:7260): an
    /// EXPLICIT row selection resolves through its enabled model+provider
    /// pair or the lane REFUSES — never a silent default fallback for a
    /// selection that no longer resolves. Only a NIL selection falls back
    /// to the persisted DEFAULT AGENT model (the temporary-lane route
    /// rule: never a first-provider guess, never a local model). The named
    /// pair is then PROVEN by the real `resolveSelected` admission.
    private func queuedInputRoute(selectedModelID: UUID?) async
        -> RunModelAssembly.ResolvedPair? {
        let store = components.modelStore
        if let selectedModelID {
            guard let model = try? await store.model(id: selectedModelID),
                  model.isEnabled,
                  let provider = try? await store.provider(id: model.providerID),
                  provider.isEnabled else { return nil }
            return try? await assembly.resolveSelected(providerID: provider.id,
                                                       modelID: model.id)
        }
        guard let preferences = try? await store.preferences(),
              let defaultID = preferences.defaultAgentModelID,
              let model = try? await store.model(id: defaultID), model.isEnabled,
              let provider = try? await store.provider(id: model.providerID),
              provider.isEnabled else { return nil }
        return try? await assembly.resolveSelected(providerID: provider.id,
                                                   modelID: model.id)
    }
}
