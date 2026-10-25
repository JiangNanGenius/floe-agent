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

// MARK: - Dispatch + real lease (mirrors dispatchGoalReview exactly)

extension FacadeRunDomain {

    /// The terminal-settlement dispatch gate. Synchronous lease attach
    /// BEFORE the first await of the lane (RUN-S3 semantics): the delete
    /// drain and root shutdown observe real owned work, never a window.
    func dispatchQueuedInputDrain(conversationID: UUID,
                                  bundle: RunPersistenceBundle) {
        guard bundle.identity == .ordinary,
              !retirementFenced, globalFence == nil,
              deleteGuards[conversationID] == nil else { return }
        // A live sibling run owns the queue: its own real terminal drains
        // (strict order, one lane per conversation).
        guard owners(conversationID: conversationID).isEmpty else { return }
        // SINGLE FLIGHT: the lane is actor state, not the registry (attach
        // does not dedupe by ownerID). A terminal arriving while the lane
        // is mid-await coalesces into the pending-wakeup flag; the lane
        // consumes it after its current launch settles — the lost-wakeup
        // boundary is closed without a second concurrent lane.
        if queueDrainActive.contains(conversationID) {
            queueDrainRecheck.insert(conversationID)
            return
        }
        let ownerID = conversationID.uuidString + ":queue-drain"
        switch RuntimeOwnedWorkRegistry.shared.attach(epoch: epoch, kind: .conversation,
                                                      ownerID: ownerID) {
        case .attached(let token):
            queueDrainActive.insert(conversationID)
            queueDrainLeases[conversationID, default: [:]][token.receipt] = token
            recordFeedEvidence(conversationID: conversationID, token: token)
            Task { [weak self] in
                guard let self else { return }
                await self.drainQueuedInput(conversationID: conversationID,
                                            bundle: bundle,
                                            token: token)
            }
        case .rejected, .invalidIdentity:
            // Lease saturation (or a foreign generation): honest skip — the
            // row stays durably queued and the next real terminal re-drains.
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

    /// Synchronous lane exit: clears the single-flight state, releases the
    /// lease, and then HONORS a parked coalesced wakeup (C05 repair) by
    /// re-dispatching ONE bounded follow-up lane through the original
    /// dispatch gate. No await between the state clears and the registry
    /// detach, so no dispatch can observe a busy lane without a live owner
    /// afterwards; the re-dispatch runs only AFTER this lane's active flag
    /// and lease are gone and re-validates identity, fences, sibling
    /// liveness and single flight itself.
    private func exitQueueDrain(conversationID: UUID,
                                token: RuntimeOwnedWorkToken,
                                bundle: RunPersistenceBundle) {
        let parked = queueDrainRecheck.remove(conversationID) != nil
        queueDrainActive.remove(conversationID)
        releaseQueueDrainLease(conversationID: conversationID, token: token)
        if parked {
            dispatchQueuedInputDrain(conversationID: conversationID,
                                     bundle: bundle)
        }
    }

    // MARK: - The lane (claim → launch → receipt; coalesced recheck loop)

    private func drainQueuedInput(conversationID: UUID,
                                  bundle: RunPersistenceBundle,
                                  token: RuntimeOwnedWorkToken) async {
        // Bounded by the durable queue bound: every iteration either
        // consumes one row (launch + receipt) or exits; refusals never
        // loop. 100 rows is the store's own maximumPendingPerConversation.
        for _ in 0..<SQLiteRunningInputStore.maximumPendingPerConversation {
            guard drainFencesOpen(conversationID: conversationID) else {
                exitQueueDrain(conversationID: conversationID, token: token,
                             bundle: bundle)
                return
            }
            let claimed: PendingUserInput?
            do {
                claimed = try await bundle.runningInputs.claimNextQueued(
                    conversationID: conversationID)
            } catch {
                // Store failure: nothing claimed, nothing to restore. The
                // rows stay queued; the next real terminal re-drains.
                exitQueueDrain(conversationID: conversationID, token: token,
                             bundle: bundle)
                return
            }
            guard let row = claimed else {
                exitQueueDrain(conversationID: conversationID, token: token,
                             bundle: bundle)
                return
            }
            // From the claim on the row is `promoting`: EVERY refusal below
            // restores it to `queued` (original body/attachments/mode
            // byte-intact) and EXITS — a refused head row is never
            // re-looped into a spin.
            guard drainFencesOpen(conversationID: conversationID) else {
                await restoreQueuedRow(bundle: bundle, id: row.id)
                exitQueueDrain(conversationID: conversationID, token: token,
                             bundle: bundle)
                return
            }
            guard let mode = Self.queuedLaunchMode(row.executionMode) else {
                // Unknown/internal execution mode: never launch what the
                // original vocabulary does not cover (browserHandoff rows
                // are already excluded by the claim SQL).
                await restoreQueuedRow(bundle: bundle, id: row.id)
                exitQueueDrain(conversationID: conversationID, token: token,
                             bundle: bundle)
                return
            }
            guard let route = await queuedInputRoute(selectedModelID: row.selectedModelID) else {
                await restoreQueuedRow(bundle: bundle, id: row.id)
                exitQueueDrain(conversationID: conversationID, token: token,
                             bundle: bundle)
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
                exitQueueDrain(conversationID: conversationID, token: token,
                               bundle: bundle)
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
                    }
                    exitQueueDrain(conversationID: conversationID,
                                   token: token, bundle: bundle)
                    return
                }
                await restoreQueuedRow(bundle: bundle, id: row.id)
                exitQueueDrain(conversationID: conversationID, token: token,
                               bundle: bundle)
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
                exitQueueDrain(conversationID: conversationID, token: token,
                             bundle: bundle)
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
            exitQueueDrain(conversationID: conversationID, token: token,
                             bundle: bundle)
            return
        }
        // Queue bound exhausted (a pathological 100-row instant chain):
        // honest exit; the next real terminal re-drains.
        exitQueueDrain(conversationID: conversationID, token: token,
                             bundle: bundle)
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
