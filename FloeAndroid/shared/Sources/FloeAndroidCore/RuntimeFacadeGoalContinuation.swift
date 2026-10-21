// SPDX-License-Identifier: MPL-2.0
//
// goal-core code batch (job-7efd60bb51d14f02, 2026-10-21) — the ORIGINAL
// post-run goal evidence review / completion gate / budgets / CAS / narrow
// in-process continuation lane for ordinary Android goal-mode runs
// (port of ConversationCenter.evaluateAndContinueGoal :5575-5756 +
// reviewGoalEvidence :5790-5825 + commitGoal :5758-5775 semantics, 1:1 on
// the SHARED byte-identical engines: GoalEvidenceReviewContract,
// GoalCompletionGate, IntelligenceStore CAS).
//
// Why this file exists (goal-lifecycle-home-control-review Part 2, proven
// by callsite): Android goal cycles previously ended at `.verifying` with
// bumped counters only — the App→core settlement seam
// (`retire(feedTerminal: true)`) had NO evidence extraction, no auxiliary
// review, no gate/blocker/budget audit, no CAS re-commit and no
// continuation producer. The engines were already qualified shared bytes;
// this lane is the missing ORIGINAL orchestration, owned by the run domain
// actor and dispatched as REAL owned work:
//
//   * Dispatch gate: the ACTUAL completed terminal of an ORDINARY goal-mode
//     run that THIS generation handed off (`goalModeRuns` +
//     `frozenRoutes`, registered at the prepared commit, cleared at real
//     retirement). Temporary paths never register and can never enter.
//   * REAL lease: an exact `.conversation` RuntimeOwnedWork token attaches
//     BEFORE the dispatching await returns and is released ONLY when the
//     awaited lane really finished — the per-conversation delete drain
//     (`feedLeaseCount`) and root retirement wait it. A caller cancel never
//     detaches early; `beginGenerationRetirement` cancels the Task handles
//     and the drain still watches the real settlement (no detach-on-cancel
//     false drain).
//   * Single-flight: the ORIGINAL `goalContinuationReservations` map keyed
//     by goal identity — one live review per goal per generation; late or
//     parallel settles mutate nothing.
//   * Frozen route: review + continuation use the run's captured
//     provider/model/adapter pair (`RunModelAssembly.ResolvedPair` frozen
//     at handoff), never a silently re-resolved later default/config.
//     Genuine route loss fails honestly (empty review verdict per the
//     original contract's fail-closed parse; continuation refuses through
//     the normal launch admission) — the worker never reads key material;
//     secret bytes stay inside the qualified ingress path.
//   * Bounded network-free writer: no network happens inside any writer
//     transaction here; the review's only durable write is the ORIGINAL
//     `saveGoalIfRevisionMatches` CAS. The continuation launch falls
//     through the SAME real launch pipeline with `messageRole`
//     "goalContinuation" (the store's frozen vocabulary) — durable terminal
//     proof, current-goal CAS and reread gate it; lost CAS never launches.
//   * In-process ONLY: no startup/background/lock resurrection, no timers,
//     no WorkManager, no `BackgroundRunCoordinator` equivalent (the original
//     marks goalContinuation non-continuable after process death). Restart
//     recovery stays user-launched goal mode (`ensureDurableGoal` reuses the
//     active goal) or checkpoint resume (`restoreGoalReservation`) — both
//     already qualified. User checkpoint/resume and the original model-driven
//     child accounting are untouched.
//   * Budget honesty: only maxCycles / maxModelCalls / maxWallClockSeconds
//     are consumed (with ACTUAL counters — `moveGoalToVerification` already
//     folded dispatched provider-attempt and tool-request counts into the
//     durable progress). The storage-only GoalBudgets fields have no
//     product consumers even on iOS (verified in the audit) and this lane
//     invents NONE; the fixed Harness budgets stay as they are.
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloePersistence
import FloeAgentRuntime
import FloeSecurity

/// The ORIGINAL single-flight reservation record
/// (`ConversationCenter.GoalContinuationReservation`): one live review per
/// goal identity, bound to the exact completed run and generation.
public struct GoalContinuationReservation: Sendable, Equatable {
    public var goalID: UUID
    public var revision: Int
    public var cycle: Int
    public var completedRunID: UUID
    public var conversationID: UUID
    public var rootEpoch: UInt64

    public init(goalID: UUID, revision: Int, cycle: Int, completedRunID: UUID,
                conversationID: UUID, rootEpoch: UInt64) {
        self.goalID = goalID
        self.revision = revision
        self.cycle = cycle
        self.completedRunID = completedRunID
        self.conversationID = conversationID
        self.rootEpoch = rootEpoch
    }
}

/// Exact actor-side bookkeeping for ONE live post-run review task, so the
/// EXISTING `run.cancel` (Main post-run stop review 2026-10-21) can reach
/// the real owned work for a run whose SERVICE lifetime already ended: the
/// review is a separate `.conversation`-leased Task keyed by its completed
/// run + owning conversation + (once resolved) the goal it reserved.
struct GoalReviewWorkHandle: Sendable {
    var conversationID: UUID
    var taskID: UUID
    var goalID: UUID?
}

// MARK: - Dispatch + real lease

extension FacadeRunDomain {
    /// Acquire-then-dispatch, structural (RUN-S3 pattern reused for the
    /// goal lane): the exact `.conversation` registry token attaches under
    /// the CURRENT epoch BEFORE this call returns, lands in the
    /// per-conversation lease map + drain evidence in the same actor step,
    /// so a delete drain or root retirement started at any later moment
    /// observes the real work. Fenced states (retirement / global
    /// admission fence / open delete guard) refuse the DISPATCH honestly —
    /// the goal's durable state is already truthful (the run boundary
    /// published `.verifying` through the service CAS; the user path
    /// confirms, a later user-launched goal cycle reviews). Saturation is
    /// a typed counter skip, never a fake delivery.
    func dispatchGoalReview(runID: UUID, conversationID: UUID,
                            frozen: RunModelAssembly.ResolvedPair,
                            bundle: RunPersistenceBundle) {
        guard bundle.identity == .ordinary, bundle.intelligence != nil,
              !retirementFenced, globalFence == nil,
              deleteGuards[conversationID] == nil else { return }
        let ownerID = conversationID.uuidString + ":goal-review:" + runID.uuidString
        switch RuntimeOwnedWorkRegistry.shared.attach(epoch: epoch, kind: .conversation,
                                                      ownerID: ownerID) {
        case .attached(let token):
            goalReviewLeases[conversationID, default: [:]][token.receipt] = token
            recordFeedEvidence(conversationID: conversationID, token: token)
            let taskID = UUID()
            guard let intelligence = bundle.intelligence else {
                releaseGoalReviewLease(conversationID: conversationID, token: token)
                return
            }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.evaluateAndContinueGoal(
                    completedRunID: runID,
                    conversationID: conversationID,
                    route: frozen,
                    bundle: bundle,
                    intelligence: intelligence)
                await self.goalReviewTaskFinished(runID: runID, taskID: taskID,
                                                  conversationID: conversationID,
                                                  token: token)
            }
            goalReviewTasks[conversationID, default: [:]][taskID] = task
            // post-run stop wiring: the EXACT handle the existing `run.cancel`
            // resolves for this completed run's live review work. Registered
            // in the SAME actor step as the lease + Task so a cancel arriving
            // at any later moment either sees real work (and stops it) or
            // sees settlement already completed (and answers truthfully).
            goalReviewWorkByRun[runID] = GoalReviewWorkHandle(
                conversationID: conversationID, taskID: taskID, goalID: nil)
        case .rejected, .invalidIdentity:
            feedStats.saturatedSkipped += 1
        }
    }

    /// Bounded REAL post-run work activity for `run.snapshot` (Main review
    /// 2026-10-21): the App keeps Stop available during the review and can
    /// show "stopping" until the actual owner settles. This is actor-owned
    /// lifecycle truth only — an inactive goal status is NOT a stopped
    /// proof, this field flipping to `none` after `stopping` is.
    func goalReviewActivity(runID: UUID) -> String {
        guard goalReviewWorkByRun[runID] != nil else { return "none" }
        return goalReviewStops.contains(runID) ? "stopping" : "active"
    }

    /// The EXPLICIT Stop seam for the existing `run.cancel`: synchronously
    /// (before any await) invalidate this run's exact review permit —
    /// stop set, goal reservation (the continuation admission) removed — and
    /// cancel the actual Task. The `.conversation` lease STAYS attached
    /// until the handler really returns (drain semantics unchanged); the
    /// completed run's durable history is never rewritten as cancelled, and
    /// no unrelated or replacement run is touched (the caller must address
    /// that run's own identity through its own cancel). Returns false when
    /// there is no live review work for this exact run (the ordinary retired/
    /// terminal paths then answer as before).
    func requestGoalReviewStop(runID: UUID, conversationID: UUID) -> Bool {
        guard let work = goalReviewWorkByRun[runID],
              work.conversationID == conversationID else { return false }
        goalReviewStops.insert(runID)
        if let goalID = work.goalID {
            // Synchronously revoke the continuation admission: the lane's
            // reservation-guarded CAS/continuation checks refuse after this
            // point; a fresh review for a NEWER activation is a different
            // completed run + (possibly) a different reservation and is NOT
            // fenced by this stop.
            goalContinuationReservations[goalID] = nil
        }
        goalReviewTasks[conversationID]?[work.taskID]?.cancel()
        return true
    }

    /// Real-completion settlement: release the exact lease (registry detach
    /// + map drop), prune the bounded task handle table. Nothing detaches
    /// early; a cancelled Task still runs this hook when its awaited work
    /// unwinds, and the drain waits it.
    private func goalReviewTaskFinished(runID: UUID, taskID: UUID,
                                        conversationID: UUID,
                                        token: RuntimeOwnedWorkToken) {
        releaseGoalReviewLease(conversationID: conversationID, token: token)
        goalReviewTasks[conversationID]?.removeValue(forKey: taskID)
        if goalReviewTasks[conversationID]?.isEmpty == true {
            goalReviewTasks[conversationID] = nil
        }
        // Settlement truth: the work handle + stop permit clear only when
        // the REAL producer returned (the snapshot activity field follows
        // this exact moment; the lease above was held until here).
        if goalReviewWorkByRun[runID]?.taskID == taskID {
            goalReviewWorkByRun.removeValue(forKey: runID)
            goalReviewStops.remove(runID)
        }
    }

    private func releaseGoalReviewLease(conversationID: UUID,
                                        token: RuntimeOwnedWorkToken) {
        RuntimeOwnedWorkRegistry.shared.detach(token)
        goalReviewLeases[conversationID]?.removeValue(forKey: token.receipt)
        if goalReviewLeases[conversationID]?.isEmpty == true {
            goalReviewLeases[conversationID] = nil
        }
    }

    /// Root retirement / privacy drain: cancel the ACTUAL lane Tasks
    /// (network unwinds cooperatively). Leases are NOT detached here — the
    /// reviewed drain waits them to the real handler return.
    func cancelGoalReviewTasks() {
        for tasks in goalReviewTasks.values {
            for task in tasks.values {
                task.cancel()
            }
        }
    }
}

// MARK: - The lane (original semantics, 1:1)

extension FacadeRunDomain {
    /// The whole post-run lifecycle ported from `evaluateAndContinueGoal`
    /// (`ConversationCenter.swift:5575-5756`): current-goal read,
    /// single-flight, durable terminal proof, evidence extraction with
    /// preparation-tool skip and reference/fingerprint dedupe, bounded
    /// tool-free auxiliary review on the run-FROZEN route, review-validated
    /// criterion/step unions, the ORIGINAL `GoalCompletionGate` verdicts,
    /// blocker/budget audits, `saveGoalIfRevisionMatches` CAS, durable
    /// re-read, and the narrow in-process continuation launch. Temporary
    /// runs never reach this method (dispatch-gated at `retire`).
    func evaluateAndContinueGoal(completedRunID: UUID,
                                 conversationID: UUID,
                                 route: RunModelAssembly.ResolvedPair,
                                 bundle: RunPersistenceBundle,
                                 intelligence: SQLiteIntelligenceStore) async {
        // Goal identity comes from the ORIGINAL durable run reservation.
        // A later current Goal can never adopt evidence from this old run.
        guard let completed = try? await bundle.runs.run(id: completedRunID),
              completed.conversationID == conversationID, completed.state == "completed",
              let goalID = completed.goalID,
              var goal = try? await intelligence.goal(id: goalID),
              goal.conversationID == conversationID, !goal.status.isTerminal else { return }
        // Stop / late-callback fence (Main reviews 2026-10-21): an explicit
        // Stop for THIS completed run (or a retirement cancel) landed while
        // the lane was being scheduled — refuse before doing anything.
        if goalReviewStops.contains(completedRunID) || Task.isCancelled { return }
        // Read the proof frozen in this run's ORIGINAL C1 event, NOT the
        // current proof at late task dispatch. A newer user C1 that already
        // committed before this task began must make this lane refuse too.
        // Goal CAS and continuation C1 both re-prove the same frozen value.
        let activationStamp: String
        let activationDigest: String
        do {
            guard let stamp = try await intelligence.frozenRunActivationIdentity(
                    runID: completedRunID, conversationID: conversationID),
                  let current = try await intelligence.conversationActivationIdentity(
                    conversationID: conversationID), current == stamp,
                  let digest = try await components.conversationRevisions
                    .digest(conversationID: conversationID), !digest.isEmpty else {
                return
            }
            activationStamp = stamp
            activationDigest = digest
        } catch {
            return
        }

        let expectedRevision = goal.revision ?? 1
        let reservation = GoalContinuationReservation(
            goalID: goal.id,
            revision: expectedRevision,
            cycle: goal.progress.cycleCount,
            completedRunID: completedRunID,
            conversationID: conversationID,
            rootEpoch: epoch)
        guard goalContinuationReservations[goal.id] == nil else { return }
        goalContinuationReservations[goal.id] = reservation
        goalReviewWorkByRun[completedRunID]?.goalID = goal.id
        defer {
            if goalContinuationReservations[goal.id] == reservation {
                goalContinuationReservations[goal.id] = nil
            }
        }

        let events = (try? await bundle.runs.events(runID: completedRunID)) ?? []
        guard let completedRun = try? await bundle.runs.run(id: completedRunID),
              completedRun.state == "completed",
              completedRun.conversationID == conversationID,
              completedRun.conversationMode == "goal",
              events.last?.kind == .terminal else {
            return
        }
        if goalReviewStops.contains(completedRunID) || Task.isCancelled { return }

        // Durable evidence extraction — ONLY successful tool results, the
        // ORIGINAL preparation-tool skip, reference dedupe on
        // run:…:event:seq and sha256 fingerprints over tool|input|
        // outputDigest/summary (original :5611-5633).
        let existingReferences = Set(goal.evidence.map(\.reference))
        var knownFingerprints = Set(goal.evidence.compactMap(\.fingerprint))
        let inputsByCallID = Dictionary(events.filter { $0.kind == .toolRequest }.compactMap { event -> (String, String)? in
            let payload = Self.eventStringMap(from: event.payloadJSON)
            guard let id = payload["id"] else { return nil }
            return (id, payload["input"] ?? "")
        }, uniquingKeysWith: { first, _ in first })
        var newEvidence: [GoalEvidence] = []
        for event in events where event.kind == .toolResult {
            let payload = Self.eventStringMap(from: event.payloadJSON)
            guard payload["status"] == "success" else { continue }
            // Discovery is preparation, not proof that the goal advanced.
            guard !GoalEvidenceReviewContract.isPreparationTool(payload["tool"] ?? "") else { continue }
            let reference = "run:\(completedRunID.uuidString):event:\(event.sequence)"
            guard !existingReferences.contains(reference) else { continue }
            let summary = String((payload["summary"] ?? payload["tool"] ?? "Successful tool result").prefix(1_000))
            let material = (payload["tool"] ?? "") + "|" + (inputsByCallID[payload["id"] ?? ""] ?? "") + "|" + (payload["outputDigest"].flatMap { $0.isEmpty ? nil : $0 } ?? payload["summary"] ?? "")
            let fingerprint = FloeDigest.sha256Hex(Data(material.utf8))
            guard knownFingerprints.insert(fingerprint).inserted else { continue }
            newEvidence.append(GoalEvidence(
                kind: .toolResult,
                reference: reference,
                summary: summary,
                capturedAt: event.createdAt,
                fingerprint: fingerprint))
        }
        goal.evidence.append(contentsOf: newEvidence)
        goal.progress.lastCheckpointAt = Date()

        if !newEvidence.isEmpty {
            let review = await reviewGoalEvidence(
                goal: goal,
                newEvidence: newEvidence,
                route: route)
            // A cancelled/stopped review stream yields the empty verdict;
            // WITHOUT this boundary the caller would still record the
            // rejection, commit state changes and continue (Main review
            // 2026-10-21). Stop wins here: nothing is mutated, nothing is
            // committed, no next cycle launches.
            if goalReviewStops.contains(completedRunID) || Task.isCancelled { return }
            // The auxiliary review call IS a model call (original counting).
            goal.progress.modelCallCount += 1
            if let blockingCondition = review.blockingCondition {
                goal.status = .blocked
                goal.progress.repeatedBlockerKey = "user-condition:\(blockingCondition)"
                goal.progress.repeatedBlockerCount = 3
            }
            if review.isValid && goal.status != .blocked {
                goal.recordProgress()
                for index in goal.steps.indices
                    where review.stepEvidence[goal.steps[index].id] != nil
                        && goal.steps[index].status != .skipped {
                    goal.steps[index].status = .completed
                    goal.steps[index].evidenceIDs = Array(Set(goal.steps[index].evidenceIDs).union(
                        review.stepEvidence[goal.steps[index].id] ?? []
                    ))
                }
                for index in goal.acceptanceCriteria.indices
                    where review.criterionEvidence[goal.acceptanceCriteria[index].id] != nil {
                    goal.acceptanceCriteria[index].isSatisfied = true
                    goal.acceptanceCriteria[index].evidenceIDs = Array(Set(
                        goal.acceptanceCriteria[index].evidenceIDs
                    ).union(review.criterionEvidence[goal.acceptanceCriteria[index].id] ?? []))
                }
                let proposal = GoalCompletionProposal(
                    goalID: goal.id,
                    criterionEvidence: Dictionary(uniqueKeysWithValues: goal.acceptanceCriteria.map {
                        ($0.id, $0.evidenceIDs)
                    }),
                    reviewModelApproved: review.isValid
                )
                let verdict = GoalCompletionGate.evaluate(goal: goal, proposal: proposal)
                if verdict.mayComplete {
                    goal.status = .completed
                    goal.progress.repeatedBlockerKey = nil
                    goal.progress.repeatedBlockerCount = 0
                    goal.updatedAt = Date()
                    guard await commitGoal(
                        goal,
                        expectedRevision: expectedRevision,
                        reservation: reservation,
                        intelligence: intelligence,
                        activationStamp: activationStamp) != nil else { return }
                    return
                }
                let onlyUserConfirmationRemains = !verdict.blockers.isEmpty
                    && verdict.blockers.allSatisfy { blocker in
                        if case .userConfirmationRequired = blocker { return true }
                        return false
                    }
                if onlyUserConfirmationRemains {
                    goal.status = .verifying
                    goal.updatedAt = Date()
                    guard await commitGoal(
                        goal,
                        expectedRevision: expectedRevision,
                        reservation: reservation,
                        intelligence: intelligence,
                        activationStamp: activationStamp) != nil else { return }
                    return
                }
            }
            if review.reviewSucceeded && !review.isValid {
                goal.recordBlocker(key: "evidence-review-rejected")
            }
            if goal.status != .blocked && goal.status != .completed { goal.status = .active }
        }

        // ORIGINAL budget audit, consumed fields only (maxCycles /
        // maxModelCalls / maxWallClockSeconds against ACTUAL durable
        // counters folded by moveGoalToVerification — no fake consumers for
        // storage-only fields, no changed Harness budgets).
        if let maxCycles = goal.budgets.maxCycles,
           goal.progress.cycleCount >= maxCycles {
            goal.status = .budgetLimited
        } else if let maxCalls = goal.budgets.maxModelCalls,
                  goal.progress.modelCallCount >= maxCalls {
            goal.status = .budgetLimited
        } else if let seconds = goal.budgets.maxWallClockSeconds,
                  let started = goal.progress.startedAt,
                  Date().timeIntervalSince(started) >= seconds {
            goal.status = .budgetLimited
        } else if newEvidence.isEmpty {
            goal.recordBlocker(key: "no-inspectable-evidence")
            if goal.status != .blocked { goal.status = .active }
        }
        goal.updatedAt = Date()
        guard let committedRevision = await commitGoal(
            goal,
            expectedRevision: expectedRevision,
            reservation: reservation,
            intelligence: intelligence,
            activationStamp: activationStamp) else { return }
        goal.revision = committedRevision
        guard goal.status == .active else { return }

        // Re-read after the durable flush. User edits, another cycle, an
        // explicit Stop or a newer activation may have advanced the Goal
        // since this evaluator acquired its snapshot. (Original
        // :5737-5741 + the 2026-10-21 stop/activation fences.)
        if goalReviewStops.contains(completedRunID) || Task.isCancelled { return }
        guard goalContinuationReservations[goal.id] == reservation,
              !retirementFenced, globalFence == nil,
              deleteGuards[conversationID] == nil,
              let durableGoal = try? await intelligence.goal(id: goal.id),
              durableGoal.revision == committedRevision,
              durableGoal.status == .active,
              // The activation stamp was just re-proven by the successful
              // durable CAS above; the conversation digest is re-checked
              // against the continuation launch's own in-transaction proof.
              let currentStamp = try? await intelligence.conversationActivationIdentity(
                  conversationID: conversationID),
              currentStamp == activationStamp else { return }

        let nextPrompt = """
        Continue the active task goal: \(goal.objective)
        This is a new execution cycle in the same task. Inspect prior messages and tool evidence, make concrete progress, and produce inspectable evidence. Do not repeat an unchanged attempt. End this cycle when no further safe action is available.
        """
        // NARROW INTERNAL continuation: the SAME real launch pipeline, the
        // SAME captured frozen route, the ORIGINAL durable role vocabulary
        // (`goalContinuation`), in-process only. Not a public command, not
        // a tool, not an incoming bool — the reservation + CAS + reread
        // above are the authority proof. A launch refusal here is honest
        // (no late retry storm; the durable thread tells the truth and the
        // user path re-arms by launching again).
        let continuationQuery = RunStartQuery(
            conversationID: conversationID,
            goal: nextPrompt,
            mode: .goal,
            providerID: route.provider.id,
            modelID: route.model.id)
        let continuationReply = await self.start(query: continuationQuery,
                                                 receipt: nil,
                                                 conversationID: conversationID,
                                                 expectedConversationRevision: activationDigest,
                                                 messageRole: "goalContinuation",
                                                 capturedLaunch: route,
                                                 continuationStopPermit: completedRunID,
                                                 expectedActivationProof: activationStamp)
        // Honest race settlement: if the continuation's own digest CAS won
        // (C1 committed before a newer user activation), this IS the real
        // same-activation cycle and runs on; if it refused, the durable
        // truth stands (goal active, newer activation current) and nothing
        // is retried from this lane. The completed parent row is NEVER
        // rewritten, and no replacement run is touched.
        _ = continuationReply
    }

    /// The original commit seam: reservation identity re-proof (Stop removes
    /// the reservation synchronously at `run.cancel`, so a stopped lane's
    /// commit refuses HERE), the retirement fence, and the durable CAS now
    /// ATOMICALLY guarded by the captured conversation-row stamp INSIDE the
    /// same writer transaction (`saveGoalIfCurrent`) — so a newer user
    /// activation that committed between any of this lane's actor hops and
    /// the write refuses the whole update, not just a racy pre-check. A lost
    /// CAS logs nothing secret and NEVER launches (no lost-CAS launch); the
    /// winning writer already moved the durable row.
    private func commitGoal(_ goal: ConversationGoal,
                            expectedRevision: Int,
                            reservation: GoalContinuationReservation,
                            intelligence: SQLiteIntelligenceStore,
                            activationStamp: String) async -> Int? {
        guard goalContinuationReservations[goal.id] == reservation,
              reservation.rootEpoch == epoch,
              !retirementFenced,
              !goalReviewStops.contains(reservation.completedRunID),
              !Task.isCancelled else { return nil }
        do {
            let saved = try await intelligence.saveGoalIfCurrent(
                goal,
                expectedRevision: expectedRevision,
                conversationID: reservation.conversationID,
                expectedActivationIdentity: activationStamp)
            guard saved else { return nil }
            return expectedRevision + 1
        } catch {
            return nil
        }
    }

    /// Bounded tool-free auxiliary review through the ORIGINAL
    /// `GoalEvidenceReviewContract` (instructions / sorted-key input /
    /// fail-closed parse: citations must be subsets of known evidence IDs,
    /// the blocking condition must equal an exact user-supplied condition,
    /// "Never infer user confirmation" is contract copy). 16 KiB output
    /// ceiling; ANY stream/credential failure yields the original empty
    /// Result (never a synthesized approval, never a default-model swap).
    private func reviewGoalEvidence(
        goal: ConversationGoal,
        newEvidence: [GoalEvidence],
        route: RunModelAssembly.ResolvedPair
    ) async -> GoalEvidenceReviewContract.Result {
        guard let input = try? GoalEvidenceReviewContract.input(goal: goal,
                                                                evidence: newEvidence) else {
            return GoalEvidenceReviewContract.Result()
        }
        let credentials: ProviderCredentials
        do {
            credentials = try await ingress.credentials(for: route.provider)
        } catch {
            return GoalEvidenceReviewContract.Result()
        }
        let request = ProviderStreamRequest(
            provider: route.provider,
            model: route.model,
            contentMessages: [
                ProviderMessage(role: "system",
                                text: GoalEvidenceReviewContract.instructions),
                ProviderMessage(role: "user", text: input),
            ])
        var output = ""
        do {
            for try await event in runAdapter(for: route.provider).stream(
                request: request, credentials: credentials) {
                if case .textDelta(let delta) = event {
                    output += delta.text
                    if output.utf8.count > 16_384 {
                        return GoalEvidenceReviewContract.Result()
                    }
                }
                if Task.isCancelled {
                    return GoalEvidenceReviewContract.Result()
                }
            }
        } catch {
            return GoalEvidenceReviewContract.Result()
        }
        return GoalEvidenceReviewContract.parse(output, goal: goal, evidence: newEvidence)
    }

    /// Mirror of `ConversationCenter.stringMap(from:)` for durable run-event
    /// payloads ([String: String] projections of the original AgentEvent
    /// JSON; a non-conforming payload decodes to empty — the original's
    /// exact behavior).
    static func eventStringMap(from json: String) -> [String: String] {
        guard let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
