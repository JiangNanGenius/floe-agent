// SPDX-License-Identifier: MPL-2.0
//
// goal-core code batch (job-7efd60bb51d14f02, 2026-10-21) — the three
// additive ordinary run-control handlers accepted by
// MAIN_RUN_CONTROL_CLOSURE_DECISION_20261020.json:
//
//   * `plan.accept`          — accept the EXACT plan revision the human saw
//     and launch it, atomically (accepted plan + optional
//     GoalFromPlanFactory goal + the ORIGINAL run/message/launch commit in
//     the SAME C1 SQLite writer transaction, AFTER the full preflight and
//     BEFORE any network; no accepted-plan irrecoverable residue; repeated
//     click / lost acknowledgement / retry / stale / retire cannot mint a
//     duplicate goal or run — durable (id, revision) conflict + row-digest
//     CAS + launch receipts, never process-only idempotency).
//   * `goal.confirm`         — the ORIGINAL explicit-human completion
//     confirmation (ThreadDetailViewModel.confirmGoalCompletion
//     :1469-1511 semantics): durable `.verifying` goal (only the durable
//     service/CAS lanes can mint that state), identity+revision-only
//     payload, the original userConfirmation evidence transform, the
//     ORIGINAL GoalCompletionGate over current steps/criteria/evidence/
//     blockers, and `saveGoalIfRevisionMatches` CAS (Main-approved
//     strengthening over the iOS unguarded save). A model or imported text
//     has NO route here; `verifying` alone is never treated as review
//     approval; refusal persists nothing.
//   * `conversation.compact` — the manual compaction lane ported step by
//     step from ConversationCenter.requestManualCompaction (:830-868): the
//     ORIGINAL engine/assembler/settings/model resolution (semantic
//     compaction key `agent.semanticContextCompaction`, default TRUE,
//     shared AppSettings semantics), the ONE shared per-conversation
//     reservation that participates in EVERY real run launch admission
//     (including the goal continuation), cooperative cancellation/drain,
//     and the ORIGINAL durable INSERT plus history/live-launch assertions
//     committed ATOMICALLY in the one writer transaction (the summary
//     network call completes BEFORE the writer; no network inside the
//     transaction; truthful shortHistory/noHistory no-ops preserve the full
//     history). Root retirement and the privacy/delete drain own this
//     non-run work exactly like the run lane.
//
// Wire discipline unchanged: v3 envelopes arrive only through the trusted
// host binder → mailbox → this actor (models, tool outputs and imported
// documents cannot submit them); all envelope3/mailbox64queued/16active/
// 64KiB bounds, error vocabularies and receipt semantics are the existing
// ones. The replies are the RB1 typed-page carrier (`RunTypedPage`):
// machine facts only — the App localizes.
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloePersistence
import FloeAgentRuntime
import FloeSecurity

// MARK: - Shared helpers

extension FacadeRunDomain {
    /// Live-launch proof for one conversation across EVERY real surface:
    /// short-lived wire admission, registered ownership (admitting →
    /// handedOff; retirement unregisters) and the shared manual-compaction
    /// reservation. Used by `goal.confirm` (the original confirm requires
    /// no live run) and `conversation.compact` (quiescent thread only).
    func conversationHasLiveLaunch(_ conversationID: UUID) -> Bool {
        if ordinaryWireAdmissions.contains(conversationID) { return true }
        if compactingConversations.contains(conversationID) { return true }
        return owners.values.contains { $0.conversationID == conversationID }
    }

    /// Generation fences shared by the lifecycle-scope controls (the SAME
    /// refusals the durable lanes already apply): retirement first, then the
    /// operation-owned global admission fence, then the per-conversation
    /// deleting guard.
    func requireLifecycleControlsAdmitted(conversationID: UUID) throws {
        if retirementFenced {
            throw RunDomainError(.sessionFenced, .generationRetired)
        }
        if isGlobalAdmissionFencedNow() {
            throw RunDomainError(.sessionFenced, .deletingGuarded)
        }
        if deleteGuards[conversationID] != nil {
            throw RunDomainError(.sessionFenced, .deletingGuarded)
        }
    }

    /// goal-core batch: the ORIGINAL English GoalBuilder defaults (catalog
    /// English values; the durable rows carry exactly the original
    /// initializer-default semantics — no invented confirmation flags, no
    /// prompt flattening).
    static let originalDefaultCriterionText =
        "The goal was verified with inspectable evidence"
    static let originalAdvanceGoalStepTitle = "Advance goal"

    /// Structured `goalDefinition` → the ORIGINAL `ConversationGoal` shape:
    /// criteria as `GoalCriterion(text:)` with initializer defaults
    /// (`requiresUserConfirmation` stays FALSE — explicit human confirm is
    /// the separate `goal.confirm` control), ONE `Advance goal` inProgress
    /// step, `.active`, `GoalProgress(startedAt:)`, revision default 1.
    /// Empty criteria fall back to the original single default criterion.
    static func structuredGoal(conversationID: UUID,
                               definition: StructuredGoalDefinition) -> ConversationGoal {
        let criteria = definition.criteria.isEmpty
            ? [GoalCriterion(text: originalDefaultCriterionText)]
            : definition.criteria.map { GoalCriterion(text: $0) }
        return ConversationGoal(
            conversationID: conversationID,
            objective: definition.objective,
            blockingConditions: definition.blockingConditions,
            stoppingConditions: definition.stoppingConditions,
            acceptanceCriteria: criteria,
            steps: [GoalStep(title: originalAdvanceGoalStepTitle,
                             status: .inProgress, order: 0)],
            status: .active,
            progress: GoalProgress(startedAt: Date()))
    }

    /// The byte-canonical English execution prompt the original
    /// `acceptLatestPlan` composes from the ACCEPTED row
    /// (ThreadDetailViewModel.swift:1395-1409; the criteria line uses the
    /// catalog English "- %@ (verified: %@)"). Composed HOST-side from the
    /// proven durable row — never from UI-supplied text (no prompt
    /// injection can ride the wire).
    static func canonicalExecutionPrompt(_ plan: PlanDraft) -> String {
        let ordered = plan.sections.sorted { $0.order < $1.order }.map {
            "## \($0.title)\n\($0.body)"
        }.joined(separator: "\n\n")
        let criteria = plan.acceptanceCriteria.map {
            "- \($0.text) (verified: \($0.verification))"
        }.joined(separator: "\n")
        return """
        Execute the accepted plan below. Preserve its ordering, verify each criterion with inspectable evidence, and continue until the safe in-scope work is complete.

        # \(plan.title)
        \(plan.summary)

        \(ordered)

        Acceptance criteria:
        \(criteria)
        """
    }

    /// Small bounded typed page (measured with the SAME
    /// `FacadeFrameBudget.serializedBytes` authority as every other page).
    private static func controlPage(_ members: [String: SettingsDomainV1.JSONValue])
        -> RunTypedPage {
        RunTypedPage(object: .object(members),
                     pageBytes: FacadeFrameBudget.serializedBytes(
                        FacadeRunDomain.unwrap(.object(members))))
    }

    static func controlReply(_ members: [String: SettingsDomainV1.JSONValue])
        -> RunDomainReply.Outcome {
        .completedPage(page: controlPage(members), nextCursor: nil)
    }
}

// MARK: - plan.accept

extension FacadeRunDomain {
    /// Wire surface for `plan.accept` (existing conversation, launch scope,
    /// floe.conversation-row.v1 digest CAS exactly like `run.start`).
    public func planAccept(envelope: RunCommandEnvelope, receipt: String,
                           correlation: String) async -> RunDomainReply {
        let query: PlanAcceptQuery
        let conversationID: UUID
        var admittedConversation: UUID?
        defer {
            if let admittedConversation { ordinaryWireAdmissions.remove(admittedConversation) }
        }
        do {
            conversationID = try envelope.requireTask()
            if envelope.runID != nil {
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            query = try PlanAcceptQuery.parse(payload: envelope.payloadValue,
                                              conversationID: conversationID)
            // Reserve before the FIRST await, exactly like `run.start`
            // (fences overlapping ordinary accepts of the same thread).
            if durable.identity == .ordinary {
                guard ordinaryWireAdmissions.insert(conversationID).inserted else {
                    throw RunDomainError(.duplicateInFlight, .launchAlreadyInFlight)
                }
                admittedConversation = conversationID
            }
            guard try await components.conversationRevisions
                .ordinaryExists(conversationID: conversationID) else {
                // Ineligible/absent answers exactly like absence (RB3
                // indistinguishability); a live temporary session has no
                // durable plan rows and lands here too.
                throw RunDomainError(.notFound, .conversationMissing)
            }
            let digest = try await components.conversationRevisions
                .digest(conversationID: conversationID) ?? ""
            try envelope.revisionMatches(
                resourceID: ConversationRowRevision.resourceID(conversationID: conversationID),
                version: digest)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error.addingPhase(.conversationProof)))
        } catch {
            return RunDomainReply(.rejected(
                RunDomainError(.persistenceUnavailable, .storeReadFailed,
                               phase: .conversationProof,
                               storePrimaryCode: Self.storePrimaryCode(of: error),
                               storeExtendedCode: Self.storeExtendedCode(of: error))))
        }
        guard let intelligence = durable.intelligence else {
            return RunDomainReply(.rejected(
                RunDomainError(.invalidState, .intelligenceStoreUnbound)))
        }
        // C0 preflight: prove the EXACT plan revision the human saw BEFORE
        // effects, then re-prove it INSIDE the writer transaction (a
        // model-driven plan.submit appending a newer revision between the
        // two steps makes the transaction refuse honestly — the user never
        // accepts a revision they did not see).
        let seen: PlanDraft
        do {
            guard let latest = try await intelligence.latestPlan(conversationID: conversationID)
            else {
                return RunDomainReply(.rejected(
                    RunDomainError(.staleRevision, .revisionMismatch, phase: .conversationProof)))
            }
            seen = latest
        } catch {
            return RunDomainReply(.rejected(
                RunDomainError(.persistenceUnavailable, .storeReadFailed,
                               phase: .conversationProof,
                               storePrimaryCode: Self.storePrimaryCode(of: error),
                               storeExtendedCode: Self.storeExtendedCode(of: error))))
        }
        guard seen.id == query.planID, seen.revision == query.planRevision,
              seen.digest == query.planDigest, seen.status == .ready,
              seen.isDecisionComplete else {
            return RunDomainReply(.rejected(
                RunDomainError(.staleRevision, .revisionMismatch, phase: .conversationProof)))
        }
        let recommendation: PlanAcceptExecution? = seen.executionRecommendation.map {
            switch $0 {
            case .normal: return .normal
            case .goal: return .goal
            }
        }
        let selectedExecution = query.execution ?? recommendation ?? .normal
        let accepted = seen.revised(
            status: .accepted,
            assumptions: seen.assumptions.map {
                PlanAssumption(id: $0.id, text: $0.text, isAccepted: true)
            },
            digest: seen.digest)
        var goalFromPlan: ConversationGoal?
        if selectedExecution == .goal {
            var goal: ConversationGoal
            do {
                goal = try GoalFromPlanFactory.makeGoal(from: accepted)
            } catch {
                return RunDomainReply(.rejected(
                    RunDomainError(.invalidState, .payloadInvalid, phase: .conversationProof)))
            }
            goal.status = .active
            goal.progress.startedAt = Date()
            goalFromPlan = goal
        }
        let prompt = Self.canonicalExecutionPrompt(accepted)
        let planID = accepted.id
        let seenRevision = seen.revision
        let seenDigest = seen.digest
        let conversationForCommit = conversationID
        let goalForCommit = goalFromPlan
        // The C1 commit hook (executed by the launch pipeline inside the
        // ONE writer transaction, after the row-digest CAS, before the
        // first durable write of the launch):
        let commit: @Sendable (Database) throws -> Void = { db in
            do {
                guard let live = try SQLiteIntelligenceStore
                    .latestPlanInTransaction(conversationID: conversationForCommit, db: db),
                      live.id == planID, live.revision == seenRevision,
                      live.digest == seenDigest, live.status == .ready,
                      live.isDecisionComplete else {
                    throw IntelligenceAtomicCommitRefusal.planStale
                }
                try SQLiteIntelligenceStore.commitPlanRevisionInTransaction(accepted, db: db)
                if let goalForCommit {
                    try SQLiteIntelligenceStore.commitGoalInTransaction(goalForCommit, db: db)
                }
            } catch let refusal as IntelligenceAtomicCommitRefusal {
                throw Self.mapAtomicRefusal(refusal)
            } catch let domain as RunDomainError {
                throw domain
            }
        }
        let inner = RunStartQuery(conversationID: conversationID,
                                  goal: prompt,
                                  mode: selectedExecution == .goal ? .goal : .chat,
                                  providerID: query.providerID,
                                  modelID: query.modelID,
                                  policy: query.policy)
        let launchReply = await start(query: inner,
                                      receipt: receipt,
                                      conversationID: conversationID,
                                      expectedConversationRevision: envelope.revision?.version,
                                      atomicIntelligence: commit)
        switch launchReply.outcome {
        case .rejected(let error):
            return RunDomainReply(.rejected(error))
        case .completedPage(let page, let cursor):
            return RunDomainReply(.completedPage(page: page, nextCursor: cursor))
        case .mutationAccepted(let detail):
            // Enrich the launch result with the durable accept facts the
            // App must re-read (runID is the REAL committed identity).
            var members: [String: SettingsDomainV1.JSONValue] = [
                "accepted": .boolean(true),
                "runID": .string(detail["runID"] ?? ""),
                "acceptedPlanRevision": .integer(Int64(accepted.revision)),
            ]
            if let goalFromPlan {
                members["goalID"] = .string(goalFromPlan.id.uuidString)
            }
            // The typed page stays on `reply.typedPage` for Main's binding
            // adapter (RB1 carrier; the small page cannot exceed the frame).
            return RunDomainReply(Self.controlReply(members))
        }
    }

    /// Closed mapping of the atomic-commit refusals into the EXISTING
    /// typed error namespace (no new codes): a moved-on plan is a stale
    /// projection, its identity conflict the duplicate-accept proof, and a
    /// fresh-identity collision an internal invariant (structurally
    /// impossible: identities mint per pipeline before the first await).
    static func mapAtomicRefusal(_ refusal: IntelligenceAtomicCommitRefusal) -> RunDomainError {
        switch refusal {
        case .planMissing, .planStale, .planNotReady, .planRevisionTaken:
            return RunDomainError(.staleRevision, .revisionMismatch)
        case .goalIdentityTaken:
            return RunDomainError(.internalError, .internal)
        case .compactionHistoryChanged:
            return RunDomainError(.staleRevision, .revisionMismatch)
        case .compactionRunActive:
            return RunDomainError(.invalidState, .conversationActive)
        case .compactionRunMissing:
            return RunDomainError(.notFound, .runMissing)
        case .compactionSummaryTooLarge:
            return RunDomainError(.payloadTooLarge, .payloadTooLarge)
        }
    }
}

// MARK: - goal.confirm

extension FacadeRunDomain {
    /// Wire surface for `goal.confirm` (conversationLifecycle scope,
    /// revision = `goal.<goalID>` / `rev:<revision>`). NO live run is
    /// required (the original confirm works after the run went terminal),
    /// and NO live run may be starting. The payload is identity+revision
    /// only: the trusted command itself is the explicit-human-intent proof
    /// (models/imported content have no route to this writer); there is no
    /// caller boolean and no invented `reviewApproved` persistence anywhere.
    public func goalConfirm(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let query: GoalConfirmQuery
        let conversationID: UUID
        do {
            conversationID = try envelope.requireTask()
            if envelope.runID != nil {
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            query = try GoalConfirmQuery.parse(payload: envelope.payloadValue,
                                               conversationID: conversationID)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        do {
            try requireLifecycleControlsAdmitted(conversationID: conversationID)
            guard durable.identity == .ordinary,
                  try await components.conversationRevisions
                    .ordinaryExists(conversationID: conversationID) else {
                throw RunDomainError(.notFound, .conversationMissing)
            }
            if conversationHasLiveLaunch(conversationID) {
                throw RunDomainError(.invalidState, .conversationActive)
            }
            try envelope.revisionMatches(
                resourceID: RunWireRevision.goalResourceID(query.goalID),
                version: RunWireRevision.goalVersion(revision: query.expectedGoalRevision))
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        guard let intelligence = durable.intelligence else {
            return RunDomainReply(.rejected(
                RunDomainError(.invalidState, .intelligenceStoreUnbound)))
        }
        let durableGoal: ConversationGoal?
        do {
            durableGoal = try await intelligence.goal(id: query.goalID)
        } catch {
            return RunDomainReply(.rejected(
                RunDomainError(.persistenceUnavailable, .storeReadFailed)))
        }
        guard let goal = durableGoal, goal.conversationID == conversationID else {
            // A goal identity this conversation does not own is
            // indistinguishable from a malformed request (no existence
            // leak across conversations).
            return RunDomainReply(.rejected(
                RunDomainError(.invalidState, .payloadInvalid)))
        }
        let expectedRevision = goal.revision ?? 1
        guard goal.status == .verifying, expectedRevision == query.expectedGoalRevision else {
            // `.verifying` is only ever minted by the durable service/CAS
            // lanes; a moved-on projection (or a mismatching revision)
            // refuses as stale — the App re-reads and answers from truth.
            return RunDomainReply(.rejected(
                RunDomainError(.staleRevision, .revisionMismatch)))
        }

        // The ORIGINAL in-memory transform (ThreadDetailViewModel
        // .confirmGoalCompletion:1469+): append the `.userConfirmation`
        // evidence bound to THIS conversation, satisfy exactly the
        // requiresUserConfirmation criteria with that evidence id, rebuild
        // the proposal, and evaluate the ORIGINAL gate. Verifying alone is
        // NOT treated as model-review approval anywhere here: every other
        // step/criterion/evidence/blocker check still runs against the
        // durable row.
        var confirmed = goal
        let evidence = GoalEvidence(
            kind: .userConfirmation,
            reference: conversationID.uuidString,
            summary: "User confirmed the goal result")
        confirmed.evidence.append(evidence)
        confirmed.acceptanceCriteria = confirmed.acceptanceCriteria.map { criterion in
            var copy = criterion
            if copy.requiresUserConfirmation {
                copy.isSatisfied = true
                copy.evidenceIDs.append(evidence.id)
            }
            return copy
        }
        let confirmedIDs = Set(
            confirmed.acceptanceCriteria
                .filter(\.requiresUserConfirmation)
                .map(\.id))
        let proposal = GoalCompletionProposal(
            goalID: confirmed.id,
            criterionEvidence: Dictionary(uniqueKeysWithValues:
                confirmed.acceptanceCriteria.map { ($0.id, $0.evidenceIDs) }),
            reviewModelApproved: true)
        let verdict = GoalCompletionGate.evaluate(goal: confirmed,
                                                  proposal: proposal,
                                                  userConfirmedCriterionIDs: confirmedIDs)
        guard verdict.mayComplete else {
            // Refusal persists NOTHING (no confirmation evidence written on
            // a blocked confirmation). Bounded machine blocker codes ride
            // the typed page; the App localizes.
            var codes: [SettingsDomainV1.JSONValue] = []
            for blocker in verdict.blockers.prefix(8) {
                codes.append(.string(Self.blockerCode(blocker)))
            }
            return RunDomainReply(Self.controlReply([
                "confirmed": .boolean(false),
                "goalID": .string(goal.id.uuidString),
                "goalRevision": .integer(Int64(expectedRevision)),
                "blockers": .array(codes),
            ]))
        }
        confirmed.status = .completed
        confirmed.updatedAt = Date()
        do {
            let saved = try await intelligence.saveGoalIfRevisionMatches(
                confirmed, expectedRevision: expectedRevision)
            guard saved else {
                // A concurrent update (review lane / user edit) won the
                // CAS; a late Root cannot commit. Refuse honestly.
                return RunDomainReply(.rejected(
                    RunDomainError(.staleRevision, .revisionMismatch)))
            }
        } catch {
            return RunDomainReply(.rejected(
                RunDomainError(.persistenceUnavailable, .storeWriteFailed)))
        }
        // Commit re-read verification (same pattern as the durable
        // moveGoalToVerification proof): report only the durable truth.
        let committed = try? await intelligence.goal(id: goal.id)
        guard let committed,
              committed.revision == expectedRevision + 1,
              committed.status == .completed,
              committed.conversationID == conversationID else {
            return RunDomainReply(.rejected(
                RunDomainError(.persistenceUnavailable, .storeWriteFailed)))
        }
        return RunDomainReply(Self.controlReply([
            "confirmed": .boolean(true),
            "goalID": .string(committed.id.uuidString),
            "goalRevision": .integer(Int64(committed.revision ?? expectedRevision + 1)),
        ]))
    }

    /// Stable machine names for the ORIGINAL gate blockers (enum case
    /// vocabulary, plus the involved identity). No prose, no secrets.
    static func blockerCode(_ blocker: GoalCompletionBlocker) -> String {
        switch blocker {
        case .wrongGoal: return "wrongGoal"
        case .goalAlreadyTerminal: return "goalAlreadyTerminal"
        case .incompleteStep(let id): return "incompleteStep:\(id.uuidString)"
        case .unsatisfiedCriterion(let id): return "unsatisfiedCriterion:\(id.uuidString)"
        case .missingEvidence(let id): return "missingEvidence:\(id.uuidString)"
        case .unknownEvidence(let id): return "unknownEvidence:\(id.uuidString)"
        case .userConfirmationRequired(let id):
            return "userConfirmationRequired:\(id.uuidString)"
        case .reviewRejected: return "reviewRejected"
        case .failedChecks: return "failedChecks"
        case .unresolvedErrors: return "unresolvedErrors"
        }
    }
}

// MARK: - conversation.compact

extension FacadeRunDomain {
    /// Wire surface for `conversation.compact` (conversationLifecycle
    /// scope, no per-row revision: concurrency is guarded core-side exactly
    /// like the original guard chain — one reservation, quiescence, and the
    /// durable writer assertions). The reply is machine-shaped
    /// `{compacted, reason, beforeTokens, afterTokens, recordID?}`; the App
    /// localizes the status line (its `applyCompactionSettled` echo already
    /// expects this shape).
    public func conversationCompact(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let query: ConversationCompactQuery
        let conversationID: UUID
        do {
            conversationID = try envelope.requireTask()
            if envelope.runID != nil {
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            query = try ConversationCompactQuery.parse(payload: envelope.payloadValue,
                                                      conversationID: conversationID)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        guard durable.identity == .ordinary, let intelligence = durable.intelligence else {
            return RunDomainReply(.rejected(
                RunDomainError(.invalidState, .intelligenceStoreUnbound)))
        }
        do {
            try requireLifecycleControlsAdmitted(conversationID: conversationID)
            // Temporary conversations never compact: there is no durable
            // history to repair and compaction records would persist
            // content. A RAM session identity answers exactly like absence.
            guard try await components.conversationRevisions
                .ordinaryExists(conversationID: conversationID) else {
                throw RunDomainError(.notFound, .conversationMissing)
            }
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(
                RunDomainError(.persistenceUnavailable, .storeReadFailed,
                               phase: .conversationProof)))
        }
        // ONE reservation, actor-synchronously inserted BEFORE the first
        // await of actual work (mirrors the original `compactingConversations`
        // + `launchCount == 0` + no-active-run gate; the reciprocal check
        // lives in EVERY real launch admission path, step 1 + step 6 of the
        // pipeline, so no launch can slip past a live compaction).
        if compactingConversations.contains(conversationID)
            || conversationHasLiveLaunch(conversationID) {
            return RunDomainReply(.rejected(
                RunDomainError(.invalidState, .conversationActive)))
        }
        compactingConversations.insert(conversationID)
        defer { compactingConversations.remove(conversationID) }

        do {
            // Step 3: honest "no history to compact" NO-OP.
            let runs: [RunRecord]
            do {
                runs = try await durable.runs.runs(conversationID: conversationID)
            } catch {
                throw RunDomainError(.persistenceUnavailable, .storeReadFailed)
            }
            guard let anchor = runs.first else {
                return RunDomainReply(Self.controlReply([
                    "compacted": .boolean(false),
                    "reason": .string("noHistory"),
                    "beforeTokens": .integer(0),
                    "afterTokens": .integer(0),
                ]))
            }
            // Steps 4-5: original assembler + compaction projection +
            // selected model's context window (default 32_768 exactly like
            // the original fallback), engine per the ORIGINAL settings
            // semantics.
            let raw = try await ConversationHistoryAssembler(store: durable.conversations)
                .build(conversationID: conversationID)
            let history = try await intelligence.applyingCompactions(
                raw, conversationID: conversationID)
            let timelineFingerprint = try await intelligence
                .messageTimelineFingerprint(conversationID: conversationID)
            let resolved = try await assembly.resolvePreferred(modelID: query.preferredModelID)
            let window = resolved?.model.limits.contextTokens ?? 32_768
            let engine = try await makeCompactionContextEngine(for: resolved)
            let result = try await engine.compact(CompactionRequest(
                context: ContextRequest(messages: history,
                                        budget: ContextBudget(contextWindowTokens: window)),
                force: true))
            // Step 6: cooperative cancellation (mailbox exact-once cancel
            // only lands BEFORE processing; mid-flight cancel comes from
            // root retirement/delete drain — both observed honestly here).
            try Task.checkCancellation()
            // Step 7: history-changed-during-compaction guard (in-process
            // sequence equality) plus the still-no-active-run re-check.
            let current = try await ConversationHistoryAssembler(store: durable.conversations)
                .build(conversationID: conversationID)
            guard raw.map({ $0.role + ":" + $0.content }) == current.map({ $0.role + ":" + $0.content }),
                  !conversationHasLiveLaunch(conversationID) else {
                throw RunDomainError(.staleRevision, .revisionMismatch)
            }
            // Step 8: truthful "history is short enough" NO-OP (nothing is
            // written, the full history stays authoritative).
            guard !result.record.sourceMessageIDs.isEmpty,
                  let summary = result.messages.first(where: {
                      $0.content.contains("Historical summary:")
                  })?.content else {
                return RunDomainReply(Self.controlReply([
                    "compacted": .boolean(false),
                    "reason": .string("shortHistory"),
                    "beforeTokens": .integer(Int64(result.record.beforeEstimatedTokens)),
                    "afterTokens": .integer(Int64(result.record.afterEstimatedTokens)),
                ]))
            }
            // Step 9: the durable summary INSERT with the FINAL in-writer
            // assertions (original `[Manual context snapshot]` prefix keeps
            // the projection predicate of `applyingCompactions` intact).
            let manualSummary = "[Manual context snapshot]\n" + summary
            let record = result.record
            do {
                try await intelligence.commitManualCompaction(
                    runID: anchor.id,
                    conversationID: conversationID,
                    record: record,
                    summary: manualSummary,
                    expectedTimelineFingerprint: timelineFingerprint)
            } catch let refusal as IntelligenceAtomicCommitRefusal {
                throw Self.mapAtomicRefusal(refusal)
            }
            // Step 10: machine facts; the App composes the localized line.
            return RunDomainReply(Self.controlReply([
                "compacted": .boolean(true),
                "reason": .string("compacted"),
                "beforeTokens": .integer(Int64(record.beforeEstimatedTokens)),
                "afterTokens": .integer(Int64(record.afterEstimatedTokens)),
                "recordID": .string(record.id.uuidString),
            ]))
        } catch is CancellationError {
            return RunDomainReply(.rejected(
                RunDomainError(.sessionFenced, .generationRetired)))
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(
                RunDomainError(.persistenceUnavailable, .storeWriteFailed,
                               storePrimaryCode: Self.storePrimaryCode(of: error),
                               storeExtendedCode: Self.storeExtendedCode(of: error))))
        }
    }

    /// ORIGINAL engine selection semantics
    /// (ConversationCenter.makeContextEngine :1169-1194): the
    /// deterministic hybrid by default; the ONE-shot bounded tool-free
    /// model summarizer only for a NON-local resolved pair while the shared
    /// settings key `agent.semanticContextCompaction` (default TRUE) is on.
    /// No resolved model => the original no-model fallback (hybrid). The
    /// 32_000-character output ceiling and the failure-to-deterministic
    /// fallback are the original `ModelContextSummarizer` contract; secret
    /// bytes never leave the qualified ingress path and the worker never
    /// reads key material.
    private func makeCompactionContextEngine(
        for resolved: RunModelAssembly.ResolvedPair?
    ) async throws -> any ContextEngine {
        guard let resolved, resolved.provider.kind != .local,
              await semanticContextCompactionEnabled() else {
            return HybridContextEngine()
        }
        let adapter = runAdapter(for: resolved.provider)
        let provider = resolved.provider
        let model = resolved.model
        let credentialsResolver = self.ingress
        return HybridContextEngine(summarizer: ModelContextSummarizer(complete: { prompt in
            let credentials = try await credentialsResolver.credentials(for: provider)
            let request = ProviderStreamRequest(
                provider: provider,
                model: model,
                messages: [(role: "user", content: prompt)],
                toolSchemas: [],
                reasoningPolicy: .disabled)
            var text = ""
            for try await event in adapter.stream(request: request, credentials: credentials) {
                if case .textDelta(let delta) = event {
                    text += delta.text
                    if text.utf8.count > 32_000 { break }
                }
            }
            return text
        }))
    }

    /// The shared settings truth: original key, original DEFAULT (true —
    /// `SettingsCenter` parity); unreadable/absent value keeps the default.
    /// A missing store binding is the same honest default, never a
    /// fabricated off-switch.
    private func semanticContextCompactionEnabled() async -> Bool {
        guard let settings = components.settings else { return true }
        guard let json = try? await settings.value(forKey: AppSettingsKey.semanticContextCompaction),
              let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(Bool.self, from: data) else {
            return true
        }
        return value
    }
}
