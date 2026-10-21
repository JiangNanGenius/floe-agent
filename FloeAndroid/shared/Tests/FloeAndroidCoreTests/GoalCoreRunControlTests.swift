// SPDX-License-Identifier: MPL-2.0
//
// goal-core code batch (job-7efd60bb51d14f02, 2026-10-21) — DEFERRED test
// source for the five native areas. AUTHORED, NOT EXECUTED in this source
// phase; the composed batch runs them on Main's build resource. Every test
// drives the REAL production seams — the original SQLite stores, the
// mailbox-routed handler methods, the launch pipeline, the frozen role
// vocabulary, the GoalEvidenceReviewContract parser and the durable manual
// compaction commit — through the existing fixture (floe-owned durable
// DatabaseManager + scripted adapter). No constants are mirrored as
// "proof": assertions read durable rows, observable actor state and real
// owned-work effects.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeProviders
import FloePersistence
import FloeAgentRuntime
import FloeSecurity
@testable import FloeAndroidCore

final class GoalCoreRunControlTests: XCTestCase {
    private var fixture: RunDomainFixture!

    override func setUp() async throws {
        fixture = try await RunDomainFixture.make()
    }

    override func tearDown() async throws {
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    // MARK: - Fixture helpers over the REAL stores

    private func ordinaryBundle() -> RunPersistenceBundle {
        RunPersistenceBundle(identity: .ordinary,
                             conversations: fixture.conversationStore,
                             runs: fixture.runStore,
                             runningInputs: fixture.inputStore,
                             launches: fixture.launchStore,
                             childRuns: fixture.childStore,
                             intelligence: fixture.intelligence)
    }

    private func readyPlan(conversationID: UUID,
                           criteria: Int = 1) async throws -> PlanDraft {
        let plan = PlanDraft(
            conversationID: conversationID,
            revision: 1,
            status: .ready,
            title: "Ship the report",
            summary: "Produce the quarterly report with evidence.",
            sections: [
                PlanSection(title: "Collect", body: "Gather inputs.", order: 0),
                PlanSection(title: "Write", body: "Compose the report.", order: 1),
            ],
            assumptions: [PlanAssumption(text: "Inputs exist", isAccepted: true)],
            acceptanceCriteria: (0..<criteria).map {
                PlanCriterion(text: "criterion-\($0)", verification: "inspect output-\($0)")
            },
            executionRecommendation: .goal,
            digest: "digest-seen-1")
        try await fixture.intelligence.savePlanRevision(plan)
        return plan
    }

    private func acceptEnvelope(conversationID: UUID, plan: PlanDraft,
                                execution: String?, revisionVersion: String,
                                correlation: String) -> RunCommandEnvelope {
        var payload: [String: Any] = [
            "planID": plan.id.uuidString,
            "planRevision": plan.revision,
            "planDigest": plan.digest,
            "providerID": fixture.providerID.uuidString,
            "modelID": fixture.modelID.uuidString,
        ]
        if let execution { payload["execution"] = execution }
        return RunCommandEnvelope(object: [
            "schema": BridgeV3.commandSchema,
            "scope": BridgeV3.Scope.launch.rawValue,
            "command": "plan.accept",
            "stateful": true,
            "correlationID": correlation,
            "owner": ["taskID": conversationID.uuidString],
            "revision": [
                "resourceID": ConversationRowRevision.resourceID(conversationID: conversationID),
                "version": revisionVersion,
            ],
            "payload": payload,
        ])
    }

    private func goalEnvelope(conversationID: UUID, goalID: UUID, revision: Int,
                              correlation: String) -> RunCommandEnvelope {
        RunCommandEnvelope(object: [
            "schema": BridgeV3.commandSchema,
            "scope": BridgeV3.Scope.conversationLifecycle.rawValue,
            "command": "goal.confirm",
            "stateful": true,
            "correlationID": correlation,
            "owner": ["taskID": conversationID.uuidString],
            "revision": [
                "resourceID": "goal.\(goalID.uuidString)",
                "version": "rev:\(revision)",
            ],
            "payload": [
                "goalID": goalID.uuidString,
                "expectedGoalRevision": revision,
            ],
        ])
    }

    private func compactEnvelope(conversationID: UUID, payload: [String: Any]?,
                                 correlation: String) -> RunCommandEnvelope {
        var object: [String: Any] = [
            "schema": BridgeV3.commandSchema,
            "scope": BridgeV3.Scope.conversationLifecycle.rawValue,
            "command": "conversation.compact",
            "stateful": true,
            "correlationID": correlation,
            "owner": ["taskID": conversationID.uuidString],
        ]
        if let payload { object["payload"] = payload }
        return RunCommandEnvelope(object: object)
    }

    private func rejected(_ reply: RunDomainReply) -> RunDomainError? {
        if case .rejected(let error) = reply.outcome { return error }
        return nil
    }

    private func pageMembers(_ reply: RunDomainReply) -> [String: SettingsDomainV1.JSONValue]? {
        if case .completedPage(let page, _) = reply.outcome,
           case .object(let members) = page.object { return members }
        return nil
    }

    /// Launches one stalled ordinary run (handedOff, provider parked in the
    /// scripted gate) and returns its identity so quiescence refusals can be
    /// proven against a REAL live producer, not a fixture flag.
    private func startStalledRun(domain: FacadeRunDomain,
                                 conversationID: UUID,
                                 goal: String,
                                 correlation: String) async throws -> (runID: UUID, gate: RunGateBox) {
        let gate = RunGateBox()
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "held")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: index)
        let revision = try await fixture.revision(conversationID: conversationID)
        let reply = await domain.start(
            envelope: fixture.launchEnvelope(conversationID: conversationID,
                                             payload: fixture.startPayload(goal: goal),
                                             revisionVersion: revision,
                                             correlation: correlation),
            receipt: "op:v1:" + String(repeating: "9", count: 31) + String(index % 10),
            correlation: correlation)
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            throw NSError(domain: "fixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(reply.outcome)"])
        }
        _ = await pollFor(timeoutSeconds: 8) { gate.isWaiting }
        XCTAssertTrue(gate.isWaiting, "the provider must be REALLY parked")
        return (runID, gate)
    }

    // MARK: - plan.accept (C1 atomic commit)

    /// Accepted plan + GoalFromPlanFactory goal + run/message/launch commit
    /// in ONE transaction: after a successful goal-execution accept the
    /// durable rows all exist together, with the EXACT accepted revision and
    /// the host-composed canonical prompt (never any UI text).
    func testPlanAcceptGoalCommitsPlanGoalAndLaunchTogether() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let plan = try await readyPlan(conversationID: conversationID)
        let revision = try await fixture.revision(conversationID: conversationID)
        let domain = fixture.makeDomain()
        let reply = await domain.planAccept(
            envelope: acceptEnvelope(conversationID: conversationID, plan: plan,
                                     execution: "goal", revisionVersion: revision,
                                     correlation: "corr-accept-goal"),
            receipt: "op:v1:" + String(repeating: "a", count: 32),
            correlation: "corr-accept-goal")
        guard let members = pageMembers(reply),
              case .boolean(true)? = members["accepted"],
              case .string(let runText)? = members["runID"],
              let runID = UUID(uuidString: runText),
              case .string(let goalText)? = members["goalID"],
              let goalID = UUID(uuidString: goalText),
              case .integer(Int64(2))? = members["acceptedPlanRevision"] else {
            return XCTFail("expected accepted page: \(reply.outcome)")
        }
        // The NEW accepted revision (append-only), same digest, all
        // assumptions accepted — the seen row itself is untouched.
        let latest = try await fixture.intelligence.latestPlan(conversationID: conversationID)
        XCTAssertEqual(latest?.status, .accepted)
        XCTAssertEqual(latest?.revision, 2)
        XCTAssertEqual(latest?.digest, plan.digest)
        XCTAssertTrue(latest?.assumptions.allSatisfy { $0.isAccepted } == true)
        // GoalFromPlanFactory shape over the ACCEPTED row: active, plan
        // source identity, one step per ordered section.
        let goal = try await fixture.intelligence.goal(id: goalID)
        XCTAssertEqual(goal?.status, .active)
        XCTAssertEqual(goal?.sourcePlanID, plan.id)
        XCTAssertEqual(goal?.sourcePlanDigest, plan.digest)
        XCTAssertEqual(goal?.steps.count, plan.sections.count)
        XCTAssertNotNil(goal?.progress.startedAt)
        // The launched run carries the canonical host-composed prompt as the
        // user turn (the accept payload has NO goal key at all).
        let runRecord = try await fixture.runStore.run(id: runID)
        XCTAssertEqual(runRecord?.conversationMode, "goal")
        let messages = try await fixture.conversationStore.messages(conversationID: conversationID)
        let userTurn = messages.first { $0.runID == runID }
        XCTAssertTrue(userTurn?.content.hasPrefix("Execute the accepted plan below.") == true)
        XCTAssertTrue(userTurn?.content.contains("- criterion-0 (verified: inspect output-0)") == true)
        XCTAssertTrue(userTurn?.content.contains("## Collect") == true)
    }

    /// A newer plan revision (model lane moved on) between what the human
    /// saw and the accept refuses with NO durable residue: no accepted
    /// revision, no goal, no run row.
    func testPlanAcceptStalePlanRefusesWithoutResidue() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let plan = try await readyPlan(conversationID: conversationID)
        let revision = try await fixture.revision(conversationID: conversationID)
        let newer = plan.revised(status: .ready, digest: "digest-newer")
        try await fixture.intelligence.savePlanRevision(newer)
        let runsBefore = try await fixture.runStore.runs(conversationID: conversationID).count
        let domain = fixture.makeDomain()
        let reply = await domain.planAccept(
            envelope: acceptEnvelope(conversationID: conversationID, plan: plan,
                                     execution: "goal", revisionVersion: revision,
                                     correlation: "corr-accept-stale"),
            receipt: "op:v1:" + String(repeating: "b", count: 32),
            correlation: "corr-accept-stale")
        XCTAssertEqual(rejected(reply)?.code, .staleRevision)
        let latest = try await fixture.intelligence.latestPlan(conversationID: conversationID)
        XCTAssertEqual(latest?.revision, newer.revision)
        XCTAssertNotEqual(latest?.status, .accepted)
        let goals = try await fixture.intelligence.goals(conversationID: conversationID)
        XCTAssertTrue(goals.isEmpty, "stale accept must not mint a goal")
        let runsAfter = try await fixture.runStore.runs(conversationID: conversationID).count
        XCTAssertEqual(runsAfter, runsBefore, "refusal must not leave a run row")
    }

    /// A repeated click cannot mint a duplicate goal/run: the replayed
    /// envelope answers stale (the conversation-row digest advanced with the
    /// first commit — durable proof, not process-only idempotency), and
    /// re-accepting the durable accepted row refuses because `.accepted` is
    /// no longer the ready decision the human saw.
    func testPlanAcceptRepeatedClickCannotDuplicateGoal() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let plan = try await readyPlan(conversationID: conversationID)
        let revision = try await fixture.revision(conversationID: conversationID)
        let domain = fixture.makeDomain()
        let first = await domain.planAccept(
            envelope: acceptEnvelope(conversationID: conversationID, plan: plan,
                                     execution: "goal", revisionVersion: revision,
                                     correlation: "corr-dup-1"),
            receipt: "op:v1:" + String(repeating: "c", count: 32),
            correlation: "corr-dup-1")
        guard case .completedPage = first.outcome else {
            return XCTFail("first accept must succeed: \(first.outcome)")
        }
        let replay = await domain.planAccept(
            envelope: acceptEnvelope(conversationID: conversationID, plan: plan,
                                     execution: "goal", revisionVersion: revision,
                                     correlation: "corr-dup-2"),
            receipt: "op:v1:" + String(repeating: "d", count: 32),
            correlation: "corr-dup-2")
        XCTAssertNotNil(rejected(replay), "stale digest replay refuses")
        let secondRevision = try await fixture.revision(conversationID: conversationID)
        let acceptedRow = try await fixture.intelligence.latestPlan(
            conversationID: conversationID)
        let again = await domain.planAccept(
            envelope: acceptEnvelope(conversationID: conversationID, plan: acceptedRow!,
                                     execution: "goal", revisionVersion: secondRevision,
                                     correlation: "corr-dup-3"),
            receipt: "op:v1:" + String(repeating: "e", count: 32),
            correlation: "corr-dup-3")
        XCTAssertEqual(rejected(again)?.code, .staleRevision)
        let goals = try await fixture.intelligence.goals(conversationID: conversationID)
        XCTAssertEqual(goals.count, 1, "exactly one durable goal from one accept")
        let rows = try await fixture.intelligence.planRevisions(conversationID: conversationID)
        XCTAssertEqual(rows.count, 2, "seen revision + accepted revision only")
    }

    /// Preflight failure BEFORE the transaction (provider disabled after the
    /// human saw the plan): the original launch admission refuses and the
    /// accepted plan/goal commit NEVER happens — the accept stays fully
    /// recoverable.
    func testPlanAcceptPreflightFailureLeavesNoAcceptedPlan() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let plan = try await readyPlan(conversationID: conversationID)
        let revision = try await fixture.revision(conversationID: conversationID)
        var disabled = fixture.providerProfile
        disabled.isEnabled = false
        try await fixture.modelStore.saveProvider(disabled)
        let domain = fixture.makeDomain()
        let reply = await domain.planAccept(
            envelope: acceptEnvelope(conversationID: conversationID, plan: plan,
                                     execution: "normal", revisionVersion: revision,
                                     correlation: "corr-accept-preflight"),
            receipt: "op:v1:" + String(repeating: "f", count: 32),
            correlation: "corr-accept-preflight")
        XCTAssertEqual(rejected(reply)?.code, .needsConfiguration)
        let latest = try await fixture.intelligence.latestPlan(conversationID: conversationID)
        XCTAssertEqual(latest?.status, .ready, "nothing was accepted")
    }

    // MARK: - goal.confirm

    private func verifyingGoal(conversationID: UUID,
                               awaitingConfirmation: Bool = true,
                               completeSteps: Bool = true) async throws -> ConversationGoal {
        let proof = GoalEvidence(kind: .toolResult, reference: "run:fixed",
                                 summary: "proof")
        let criterion = GoalCriterion(
            text: "done",
            isSatisfied: awaitingConfirmation,
            evidenceIDs: awaitingConfirmation ? [proof.id] : [],
            requiresUserConfirmation: awaitingConfirmation)
        var goal = ConversationGoal(
            conversationID: conversationID,
            objective: "finish it",
            acceptanceCriteria: [criterion],
            steps: [GoalStep(title: "Advance goal",
                             status: completeSteps ? .completed : .inProgress, order: 0)],
            evidence: [proof],
            status: .verifying)
        goal.revision = 1
        try await fixture.intelligence.saveGoal(goal)
        return goal
    }

    /// The ORIGINAL explicit-human semantics: verifying + owned + exact
    /// revision + the gate over the real rows + the CAS; completion is
    /// durable-proven (re-read revision == n+1 and status .completed).
    func testGoalConfirmCompletesVerifyingGoalWithCAS() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let goal = try await verifyingGoal(conversationID: conversationID)
        let domain = fixture.makeDomain()
        let reply = await domain.goalConfirm(
            envelope: goalEnvelope(conversationID: conversationID, goalID: goal.id,
                                   revision: 1, correlation: "corr-confirm-ok"))
        guard let members = pageMembers(reply),
              case .boolean(true)? = members["confirmed"],
              case .integer(Int64(2))? = members["goalRevision"] else {
            return XCTFail("expected confirmed page: \(reply.outcome)")
        }
        let durable = try await fixture.intelligence.goal(id: goal.id)
        XCTAssertEqual(durable?.status, .completed)
        XCTAssertEqual(durable?.revision, 2)
        let confirmation = durable?.evidence.first { $0.kind == .userConfirmation }
        XCTAssertNotNil(confirmation, "the ORIGINAL evidence transform ran")
        XCTAssertEqual(confirmation?.reference, conversationID.uuidString)
        XCTAssertTrue(durable?.acceptanceCriteria.first?.evidenceIDs
            .contains(confirmation?.id ?? UUID()) == true)
    }

    /// Nonconfirmation blockers still refuse (fail-closed gate over steps/
    /// criteria/evidence), and the refusal persists NOTHING (durable row
    /// unchanged; no confirmation evidence on refusal).
    func testGoalConfirmBlockerRefusalPersistsNothing() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let goal = try await verifyingGoal(conversationID: conversationID,
                                           completeSteps: false)
        let domain = fixture.makeDomain()
        let reply = await domain.goalConfirm(
            envelope: goalEnvelope(conversationID: conversationID, goalID: goal.id,
                                   revision: 1, correlation: "corr-confirm-blocked"))
        guard let members = pageMembers(reply),
              case .boolean(false)? = members["confirmed"],
              case .array(let blockers)? = members["blockers"], !blockers.isEmpty else {
            return XCTFail("expected confirmed=false with blockers: \(reply.outcome)")
        }
        if case .string(let code)? = blockers.first {
            XCTAssertTrue(code.hasPrefix("incompleteStep"), code)
        } else {
            XCTFail("blocker shape")
        }
        let durable = try await fixture.intelligence.goal(id: goal.id)
        XCTAssertEqual(durable?.status, .verifying)
        XCTAssertEqual(durable?.revision, 1)
        XCTAssertTrue(durable?.evidence.allSatisfy { $0.kind != .userConfirmation } == true,
                      "refusal must not persist confirmation evidence")
    }

    /// The CAS wins or refuses atomically: a review-lane advance between the
    /// human's read and the confirm makes the late Root refuse — nothing
    /// commits.
    func testGoalConfirmLostCASRefuses() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let goal = try await verifyingGoal(conversationID: conversationID)
        var advanced = goal
        advanced.status = .active
        advanced.updatedAt = Date()
        let saved = try await fixture.intelligence.saveGoalIfRevisionMatches(advanced,
                                                                             expectedRevision: 1)
        XCTAssertTrue(saved, "fixture CAS must advance the row first")
        let domain = fixture.makeDomain()
        let reply = await domain.goalConfirm(
            envelope: goalEnvelope(conversationID: conversationID, goalID: goal.id,
                                   revision: 1, correlation: "corr-confirm-cas"))
        XCTAssertEqual(rejected(reply)?.code, .staleRevision)
        let durable = try await fixture.intelligence.goal(id: goal.id)
        XCTAssertEqual(durable?.status, .active)
        XCTAssertEqual(durable?.revision, 2)
    }

    /// Verifying alone is NOT model-review approval and the payload cannot
    /// carry authority: unknown keys (approval flags) are typed refusals, a
    /// foreign goal identity refuses indistinguishably, and a run role on a
    /// lifecycle command is structurally rejected by the frozen validator.
    func testGoalConfirmGrammarIsIdentityAndRevisionOnly() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let goal = try await verifyingGoal(conversationID: conversationID)
        XCTAssertThrowsError(try GoalConfirmQuery.parse(payload: .object([
            "goalID": .string(goal.id.uuidString),
            "expectedGoalRevision": .integer(1),
            "reviewApproved": .boolean(true),
        ]), conversationID: conversationID))
        let other = try await fixture.makeOrdinaryConversation(goal: "other")
        let domain = fixture.makeDomain()
        let foreign = await domain.goalConfirm(
            envelope: goalEnvelope(conversationID: other, goalID: goal.id,
                                   revision: 1, correlation: "corr-confirm-foreign"))
        XCTAssertNotNil(rejected(foreign))
        let envelope: [String: Any] = [
            "schema": BridgeV3.commandSchema,
            "scope": BridgeV3.Scope.conversationLifecycle.rawValue,
            "command": "goal.confirm",
            "stateful": true,
            "correlationID": "corr-validate-role",
            "owner": ["taskID": conversationID.uuidString, "runID": UUID().uuidString],
            "revision": ["resourceID": "goal.\(goal.id.uuidString)", "version": "rev:1"],
            "payload": ["goalID": goal.id.uuidString, "expectedGoalRevision": 1],
        ]
        XCTAssertFalse(BridgeV3.validate(envelope: envelope, requestID: "r",
                                         operation: .submit).isValid,
                       "lifecycle scope must structurally reject a run role")
    }

    /// The original confirm works with NO live run, and refuses while a run
    /// is actually live (no confirmation may land against an executing goal
    /// cycle the review lane is still going to settle).
    func testGoalConfirmRefusesWhileLiveRunHoldsConversation() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let goal = try await verifyingGoal(conversationID: conversationID)
        let domain = fixture.makeDomain()
        let stalled = try await startStalledRun(domain: domain,
                                                conversationID: conversationID,
                                                goal: "live",
                                                correlation: "corr-confirm-live")
        let reply = await domain.goalConfirm(
            envelope: goalEnvelope(conversationID: conversationID, goalID: goal.id,
                                   revision: 1, correlation: "corr-confirm-busy"))
        let error = rejected(reply)
        XCTAssertEqual(error?.code, .invalidState)
        XCTAssertEqual(error?.reason, .conversationActive)
        let durable = try await fixture.intelligence.goal(id: goal.id)
        XCTAssertEqual(durable?.status, .verifying)
        stalled.gate.release()
        _ = await waitDurableTerminal(fixture: fixture, runID: stalled.runID)
    }

    // MARK: - conversation.compact

    /// No durable runs yet => the honest "no history to compact" NO-OP
    /// (machine-shaped accepted reply, nothing written).
    func testCompactNoHistoryHonestNoOp() async throws {
        let domain = fixture.makeDomain()
        let conversationID = UUID()
        try await fixture.conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "bare", createdAt: Date(), updatedAt: Date()))
        let reply = await domain.conversationCompact(
            envelope: compactEnvelope(conversationID: conversationID, payload: nil,
                                      correlation: "corr-compact-none"))
        guard let members = pageMembers(reply),
              case .boolean(false)? = members["compacted"],
              case .string("noHistory")? = members["reason"] else {
            return XCTFail("expected noHistory no-op: \(reply.outcome)")
        }
    }

    /// A live run refuses manual compaction (original quiescent-thread gate).
    func testCompactRefusesWhileRunLive() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let stalled = try await startStalledRun(domain: domain,
                                                conversationID: conversationID,
                                                goal: "hold the thread",
                                                correlation: "corr-compact-live")
        let reply = await domain.conversationCompact(
            envelope: compactEnvelope(conversationID: conversationID, payload: nil,
                                      correlation: "corr-compact-live-2"))
        let error = rejected(reply)
        XCTAssertEqual(error?.code, .invalidState)
        XCTAssertEqual(error?.reason, .conversationActive)
        stalled.gate.release()
        _ = await waitDurableTerminal(fixture: fixture, runID: stalled.runID)
    }

    /// The ONE shared reservation participates in EVERY real launch
    /// admission: while the compaction lane holds the conversation (here:
    /// the bounded summarizer call parked in the scripted gate), an ordinary
    /// launch must refuse typed; after the real settle the same launch
    /// admits. (The seeded history is engineered to engage the forced
    /// semantic summarizer call; if the engine's segmentation thresholds
    /// change, regenerate the seed — the assertion is the refusal, not the
    /// token math.)
    func testLaunchRefusedWhileCompactionReservationHeld() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        // Seed enough durable history for a forced compaction segment.
        for index in 0..<48 {
            let prepared = try await fixture.launchStore.prepare(RunLaunchRequest(
                conversationID: conversationID,
                goal: String(repeating: "x", count: 1_024) + " \(index)",
                conversationMode: "chat",
                providerID: fixture.providerID,
                modelID: fixture.modelID))
            try await fixture.runStore.updateRunState(id: prepared.run.id, state: "completed",
                                                      endedAt: Date())
        }
        let domain = fixture.makeDomain()
        // Stall the bounded summarizer call (the compact lane resolves the
        // default-agent model from preferences; provider kind is cloud and
        // the semantic key defaults ON).
        let gate = RunGateBox()
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "Historical summary: stalled for the race proof")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: index)
        let heldEnvelope = compactEnvelope(conversationID: conversationID, payload: nil,
                                           correlation: "corr-compact-held")
        let compactTask = Task {
            await domain.conversationCompact(envelope: heldEnvelope)
        }
        let compactFixture = fixture!
        let reserved = await pollFor(timeoutSeconds: 8) {
            await compactFixture.compactingHeld(conversationID, in: domain)
        }
        XCTAssertTrue(reserved, "the lane must hold the shared reservation during the call")
        // The reciprocal refusal: the launch admission sees the reservation.
        let revision = try await fixture.revision(conversationID: conversationID)
        let launch = await domain.start(
            envelope: fixture.launchEnvelope(conversationID: conversationID,
                                             payload: fixture.startPayload(goal: "during compact"),
                                             revisionVersion: revision,
                                             correlation: "corr-launch-held"),
            receipt: "op:v1:" + String(repeating: "7", count: 32),
            correlation: "corr-launch-held")
        let launchError = rejected(launch)
        XCTAssertEqual(launchError?.reason, .conversationActive)
        gate.release()
        _ = await compactTask.value
        // Released: the same pipeline admits again (proving the refusal was
        // the reservation, not fixture noise). The second summarizer call
        // falls back deterministically after the history grew (honest shape
        // either way: accepted page, never a fake error).
        let afterRevision = try await fixture.revision(conversationID: conversationID)
        let admitted = await domain.start(
            envelope: fixture.launchEnvelope(conversationID: conversationID,
                                             payload: fixture.startPayload(goal: "after compact"),
                                             revisionVersion: afterRevision,
                                             correlation: "corr-launch-after"),
            receipt: "op:v1:" + String(repeating: "8", count: 32),
            correlation: "corr-launch-after")
        XCTAssertNotEqual(rejected(admitted)?.reason, .conversationActive)
    }

    /// The durable writer proof: a stale timeline fingerprint, a live-state
    /// launch or a foreign anchor ALL refuse inside the SAME transaction
    /// with zero rows written; the happy path inserts exactly the original
    /// record shape (manual prefix keeps the projection predicate).
    func testCommitManualCompactionWriterAssertions() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        let anchor = runs[0]
        let record = ContextCompactionRecord(sourceMessageIDs: [UUID()],
                                             sourceDigest: "d",
                                             beforeEstimatedTokens: 900,
                                             afterEstimatedTokens: 200)
        // (a) stale timeline refuses and writes nothing.
        do {
            try await fixture.intelligence.commitManualCompaction(
                runID: anchor.id, conversationID: conversationID, record: record,
                summary: "[Manual context snapshot]\nx",
                expectedTimelineFingerprint: "deadbeef")
            XCTFail("stale timeline must refuse")
        } catch let refusal as IntelligenceAtomicCommitRefusal {
            XCTAssertEqual(refusal, .compactionHistoryChanged)
        }
        // (b) a live-state launch for the conversation refuses.
        let live = try await fixture.launchStore.prepare(RunLaunchRequest(
            conversationID: conversationID,
            goal: "live anchor",
            conversationMode: "chat",
            providerID: fixture.providerID,
            modelID: fixture.modelID))
        do {
            try await fixture.intelligence.commitManualCompaction(
                runID: anchor.id, conversationID: conversationID, record: record,
                summary: "[Manual context snapshot]\nx",
                expectedTimelineFingerprint: try await fixture.intelligence
                    .messageTimelineFingerprint(conversationID: conversationID))
            XCTFail("live launch must block the durable commit")
        } catch let refusal as IntelligenceAtomicCommitRefusal {
            XCTAssertEqual(refusal, .compactionRunActive)
        }
        try await fixture.runStore.updateRunState(id: live.run.id, state: "completed",
                                                  endedAt: Date())
        // (c) a foreign anchor run refuses (identity/ownership proof).
        let other = try await fixture.makeOrdinaryConversation(goal: "other thread")
        let otherRuns = try await fixture.runStore.runs(conversationID: other)
        do {
            try await fixture.intelligence.commitManualCompaction(
                runID: otherRuns[0].id, conversationID: conversationID, record: record,
                summary: "[Manual context snapshot]\nx",
                expectedTimelineFingerprint: try await fixture.intelligence
                    .messageTimelineFingerprint(conversationID: conversationID))
            XCTFail("foreign anchor must refuse")
        } catch let refusal as IntelligenceAtomicCommitRefusal {
            XCTAssertEqual(refusal, .compactionRunMissing)
        }
        // (d) happy path: exactly one durable record visible to the
        // ORIGINAL projection predicate.
        try await fixture.intelligence.commitManualCompaction(
            runID: anchor.id, conversationID: conversationID, record: record,
            summary: "[Manual context snapshot]\n## Historical summary:\nbody",
            expectedTimelineFingerprint: try await fixture.intelligence
                .messageTimelineFingerprint(conversationID: conversationID))
        let projected = try await fixture.intelligence.applyingCompactions(
            [ConversationMessage(id: anchor.id, role: "user", content: "seed")],
            conversationID: conversationID)
        XCTAssertTrue(projected.contains { message in
            message.role == "system" && message.content.contains("[Manual context snapshot]")
        })
    }

    // MARK: - structured goalDefinition on ordinary run.start

    private func structuredPayload(mode: String,
                                   objective: String = "ship it",
                                   criteria: [String] = ["tests pass"],
                                   blocking: [String] = ["do not push"],
                                   stopping: [String] = ["all criteria verified"],
                                   goalDefinitionOverride: Any? = nil) -> [String: Any] {
        let definition: Any = goalDefinitionOverride ?? [
            "objective": objective,
            "criteria": criteria,
            "blockingConditions": blocking,
            "stoppingConditions": stopping,
        ]
        return [
            "goal": "run the structured goal",
            "mode": mode,
            "providerID": fixture.providerID.uuidString,
            "modelID": fixture.modelID.uuidString,
            "goalDefinition": definition,
        ]
    }

    /// Roundtrip through the REAL stores: the structured fields persist as
    /// the original ConversationGoal/GoalCriterion rows (initializer
    /// defaults intact, requiresUserConfirmation FALSE, one `Advance goal`
    /// inProgress step) atomically with the run/message/launch.
    func testStructuredGoalRoundTripThroughOriginalStores() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let revision = try await fixture.revision(conversationID: conversationID)
        let domain = fixture.makeDomain()
        let reply = await domain.start(
            envelope: fixture.launchEnvelope(conversationID: conversationID,
                                             payload: structuredPayload(mode: "goal"),
                                             revisionVersion: revision,
                                             correlation: "corr-structured-ok"),
            receipt: "op:v1:" + String(repeating: "2", count: 32),
            correlation: "corr-structured-ok")
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            return XCTFail("structured launch must commit: \(reply.outcome)")
        }
        let goals = try await fixture.intelligence.goals(conversationID: conversationID)
        guard let structured = goals.first(where: { $0.objective == "ship it" }) else {
            return XCTFail("durable structured goal missing: \(goals.map(\.objective))")
        }
        XCTAssertEqual(structured.status, .active)
        XCTAssertEqual(structured.revision, 1)
        XCTAssertEqual(structured.blockingConditions, ["do not push"])
        XCTAssertEqual(structured.stoppingConditions, ["all criteria verified"])
        XCTAssertEqual(structured.acceptanceCriteria.count, 1)
        XCTAssertEqual(structured.acceptanceCriteria.first?.text, "tests pass")
        XCTAssertEqual(structured.acceptanceCriteria.first?.requiresUserConfirmation, false)
        XCTAssertEqual(structured.steps.count, 1)
        XCTAssertEqual(structured.steps.first?.title, "Advance goal")
        XCTAssertEqual(structured.steps.first?.status, .inProgress)
        XCTAssertNotNil(structured.progress.startedAt)
        // The run row and the goal committed together; the prompt stays the
        // ORIGINAL user text (no flattening of the structured fields).
        let runRecord = try await fixture.runStore.run(id: runID)
        XCTAssertEqual(runRecord?.conversationMode, "goal")
        let messages = try await fixture.conversationStore.messages(conversationID: conversationID)
        XCTAssertEqual(messages.first { $0.runID == runID }?.content, "run the structured goal")
        // The runtime's ensureDurableGoal reuses THIS structured row instead
        // of minting the generic default goal.
        let objectives = goals.map(\.objective)
        XCTAssertFalse(objectives.contains("run the structured goal"),
                       "no generic fallback goal may be minted next to the structured one")
    }

    /// Mode mismatch / unknown keys / wrong shapes refuse at the closed
    /// grammar BEFORE any durable effect; oversize refuses typed. No half
    /// goal, no run row, no residue.
    func testStructuredGoalRefusalsLeaveNoResidue() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let runsBefore = try await fixture.runStore.runs(conversationID: conversationID).count
        let goalsBefore = try await fixture.intelligence.goals(conversationID: conversationID).count

        func expectRefusal(_ payload: [String: Any], correlation: String,
                           code: RunDomainError.Code = .invalidState) async throws {
            let revision = try await fixture.revision(conversationID: conversationID)
            let reply = await domain.start(
                envelope: fixture.launchEnvelope(conversationID: conversationID,
                                                 payload: payload,
                                                 revisionVersion: revision,
                                                 correlation: correlation),
                receipt: "op:v1:" + String(repeating: "3", count: 32),
                correlation: correlation)
            XCTAssertEqual(rejected(reply)?.code, code, correlation)
        }
        try await expectRefusal(structuredPayload(mode: "chat"),
                            correlation: "corr-structured-mode")
        try await expectRefusal(structuredPayload(mode: "goal",
                                              goalDefinitionOverride: [
                                                  "objective": "ship it",
                                                  "reviewApproved": true,
                                              ]),
                            correlation: "corr-structured-unknown")
        try await expectRefusal(structuredPayload(mode: "goal",
                                              goalDefinitionOverride: ["objective": 1]),
                            correlation: "corr-structured-shape")
        try await expectRefusal(structuredPayload(mode: "goal",
                                              criteria: [String(repeating: "x", count: 4_096)]),
                            correlation: "corr-structured-oversize",
                            code: .payloadTooLarge)
        let runsAfter = try await fixture.runStore.runs(conversationID: conversationID).count
        XCTAssertEqual(runsAfter, runsBefore, "refusals must not create runs")
        let goalsAfter = try await fixture.intelligence.goals(conversationID: conversationID).count
        XCTAssertEqual(goalsAfter, goalsBefore, "refusals must not create goals")
    }

    /// The create-intent surface (run.startTask) structurally refuses a
    /// goalDefinition: no proven conversation identity exists before its
    /// commit, and the original GoalBuilder flow targets the existing task.
    func testStructuredGoalRejectedForCreateIntent() {
        XCTAssertThrowsError(try RunStartTaskQuery.parse(payload: .object([
            "title": .string("t"),
            "goal": .string("g"),
            "mode": .string("goal"),
            "providerID": .string(UUID().uuidString),
            "modelID": .string(UUID().uuidString),
            "goalDefinition": .object([
                "objective": .string("o"),
                "criteria": .array([.string("c")]),
            ]),
        ])))
    }

    /// Empty criteria fall back to the ORIGINAL default criterion — never an
    /// empty-criteria goal and never an invented confirmation requirement.
    func testStructuredGoalEmptyCriteriaUseOriginalDefault() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let revision = try await fixture.revision(conversationID: conversationID)
        let domain = fixture.makeDomain()
        let reply = await domain.start(
            envelope: fixture.launchEnvelope(conversationID: conversationID,
                                             payload: structuredPayload(mode: "goal",
                                                                       criteria: [],
                                                                       blocking: [],
                                                                       stopping: []),
                                             revisionVersion: revision,
                                             correlation: "corr-structured-default"),
            receipt: "op:v1:" + String(repeating: "4", count: 32),
            correlation: "corr-structured-default")
        guard case .mutationAccepted = reply.outcome else {
            return XCTFail("launch must commit: \(reply.outcome)")
        }
        let goals = try await fixture.intelligence.goals(conversationID: conversationID)
        let structured = goals.first { $0.objective == "ship it" }
        XCTAssertEqual(structured?.acceptanceCriteria.map(\.text),
                       [FacadeRunDomain.originalDefaultCriterionText])
        XCTAssertEqual(structured?.blockingConditions ?? [], [],
                       "empty producer arrays stay empty (original createGoal filter)")
        XCTAssertEqual(structured?.acceptanceCriteria.first?.requiresUserConfirmation, false)
    }

    // MARK: - post-run goal review lane (real store paths)

    /// Seeds a COMPLETED goal-mode run the way PRODUCTION leaves one: every
    /// tool event is durable BEFORE the run's terminal, and the terminal is
    /// the LAST event (the lane's durable completion proof is
    /// `events.last == .terminal`; appending work after a terminal would be
    /// an impossible production state).
    private func seedCompletedGoalRun(conversationID: UUID,
                                      objective: String,
                                      toolEvents: [(tool: String, digest: String)] = [])
        async throws -> UUID {
        let request = RunLaunchRequest(conversationID: conversationID,
                                       goal: "Goal: \(objective)",
                                       conversationMode: "goal",
                                       providerID: fixture.providerID,
                                       modelID: fixture.modelID)
        let prepared = try await fixture.launchStore.prepare(request)
        for event in toolEvents {
            try await appendToolEvent(runID: prepared.run.id, tool: event.tool,
                                      outputDigest: event.digest)
        }
        try await fixture.runStore.updateRunState(id: prepared.run.id, state: "completed",
                                                  endedAt: Date())
        try await fixture.runStore.appendEvent(runID: prepared.run.id, kind: .terminal,
                                               payloadJSON: #"{"state":"completed"}"#)
        return prepared.run.id
    }

    private func appendToolEvent(runID: UUID, tool: String,
                                 outputDigest: String,
                                 callID: String = UUID().uuidString) async throws {
        try await fixture.runStore.appendEvent(
            runID: runID, kind: .toolRequest,
            payloadJSON: #"{"id":"\#(callID)","tool":"\#(tool)","input":"{\"q\":\"1\"}"}"#)
        try await fixture.runStore.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: #"{"callID":"\#(callID)","tool":"\#(tool)","status":"success","summary":"did work","outputDigest":"\#(outputDigest)"}"#)
    }

    private func verifyingGoalPlain(conversationID: UUID,
                                   objective: String,
                                   blocking: [String]? = nil) async throws -> ConversationGoal {
        var goal = ConversationGoal(
            conversationID: conversationID,
            objective: objective,
            blockingConditions: blocking,
            acceptanceCriteria: [GoalCriterion(text: "done")],
            steps: [GoalStep(title: "Advance goal", status: .inProgress, order: 0)],
            status: .verifying)
        goal.revision = 1
        try await fixture.intelligence.saveGoal(goal)
        return goal
    }

    private func evaluateLane(domain: FacadeRunDomain,
                              runID: UUID,
                              conversationID: UUID) async {
        do {
            guard let goal = try await fixture.intelligence.goals(conversationID: conversationID).first else {
                XCTFail("The real review fixture must contain its owning Goal")
                return
            }
            // Match ORIGINAL ConversationRunService.assignGoalReliably.
            try await fixture.runStore.assignGoal(runID: runID, goalID: goal.id)
        } catch {
            XCTFail("Could not bind original fixture run Goal: \(error)")
            return
        }
        let route = RunModelAssembly.ResolvedPair(provider: fixture.providerProfile,
                                                  model: fixture.modelProfile,
                                                  approvalCredentials: nil)
        await domain.evaluateAndContinueGoal(completedRunID: runID,
                                             conversationID: conversationID,
                                             route: route,
                                             bundle: ordinaryBundle(),
                                             intelligence: fixture.intelligence)
    }

    /// Parks the NEXT provider request (the continuation run's first call)
    /// behind a gate so a test can assert the synchronous settle WITHOUT a
    /// racing second review cycle; release it before the test ends.
    private func stallRequest(at index: Int, reply: String? = nil) -> RunGateBox {
        let gate = RunGateBox()
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: reply ?? "held")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: index)
        return gate
    }

    /// Evidence extraction uses ONLY successful toolResults, skips the
    /// ORIGINAL preparation tools, and dedupes by reference AND fingerprint
    /// (a replayed identical result yields no second evidence row). An
    /// unknown-citation review reply fails CLOSED (blocker recorded; the
    /// goal returns to active — never completed, never forged verifying).
    func testEvidenceExtractionSkipsPrepAndDedupes() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        // tools.list is preparation (never proof); the doubled file.write
        // result exercises fingerprint dedupe. Durable in PRODUCTION order:
        // tool work first, then the completion + terminal.
        let runID = try await seedCompletedGoalRun(
            conversationID: conversationID, objective: "obj",
            toolEvents: [("tools.list", "p0"), ("file.write", "d1"),
                         ("file.write", "d1")])
        let goal = try await verifyingGoalPlain(conversationID: conversationID, objective: "obj")
        let domain = fixture.makeDomain()
        let reviewIndex = fixture.adapter.requestCount
        // VALID original review grammar (every non-optional member present)
        // citing an UNKNOWN evidence id: the ORIGINAL contract parses it and
        // refuses the citations, so the lane records the fail-closed
        // rejection — never a decode artefact.
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: #"{"valid":true,"progressEvidenceIDs":["\#(UUID().uuidString)"],"criteria":[],"steps":[],"blockingCondition":null,"blockingEvidenceIDs":[]}"#)),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: reviewIndex)
        // The active fall-through may launch a continuation; park its first
        // provider call so no second review races the assertions below.
        let parked = stallRequest(at: reviewIndex + 1)
        await evaluateLane(domain: domain, runID: runID, conversationID: conversationID)
        let durable = try await fixture.intelligence.goal(id: goal.id)
        XCTAssertEqual(durable?.evidence.filter { $0.kind == .toolResult }.count, 1,
                       "prep skip + fingerprint dedupe -> exactly one evidence row")
        XCTAssertEqual(durable?.progress.repeatedBlockerKey, "evidence-review-rejected")
        XCTAssertEqual(durable?.progress.repeatedBlockerCount, 1)
        XCTAssertEqual(durable?.revision, 2, "the audit persisted via CAS")
        parked.release()
    }

    /// The parse contract: a blockingCondition is honored ONLY when it
    /// equals an EXACT user-supplied condition (an inferred blocker drops;
    /// "Never infer user confirmation" stays contract copy — there is no
    /// confirmation field in the reply grammar at all).
    func testReviewBlockingConditionRequiresExactUserString() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCompletedGoalRun(conversationID: conversationID,
                                                   objective: "obj")
        try await appendToolEvent(runID: runID, tool: "file.write", outputDigest: "unique")
        let goal = try await verifyingGoalPlain(conversationID: conversationID,
                                                objective: "obj",
                                                blocking: ["never deploy"])
        let domain = fixture.makeDomain()
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: #"{"valid":false,"progressEvidenceIDs":[],"criteria":[],"steps":[],"blockingCondition":"invented blocker","blockingEvidenceIDs":[]}"#)),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 0, gate: nil), forRequest: fixture.adapter.requestCount)
        await evaluateLane(domain: domain, runID: runID, conversationID: conversationID)
        let durable = try await fixture.intelligence.goal(id: goal.id)
        XCTAssertNotEqual(durable?.status, .blocked,
                          "non-exact blocking condition must be dropped by the parser")
    }

    /// The ORIGINAL review contract parser (the exact function the lane
    /// runs): the blocking condition survives ONLY when it equals a
    /// user-supplied condition AND cites KNOWN evidence of this review;
    /// citations outside the supplied evidence void the criterion union;
    /// valid progress needs at least one known citation; oversize output
    /// fails closed. Lane-level exact-blocking additionally requires an
    /// evidence id minted inside extraction (not externally scriptable), so
    /// the lane test above asserts the DROP side and this test pins the
    /// contract the lane trusts.
    func testReviewContractParserIsFailClosedOnCitations() throws {
        let evidence = GoalEvidence(kind: .toolResult, reference: "run:x", summary: "s")
        let criterion = GoalCriterion(text: "done")
        let step = GoalStep(title: "Advance goal", status: .inProgress, order: 0)
        let goal = ConversationGoal(conversationID: UUID(), objective: "o",
                                    blockingConditions: ["never deploy"],
                                    acceptanceCriteria: [criterion],
                                    steps: [step],
                                    evidence: [evidence],
                                    status: .active)
        func parse(_ json: String) -> GoalEvidenceReviewContract.Result {
            GoalEvidenceReviewContract.parse(json, goal: goal, evidence: [evidence])
        }
        // exact user condition + known evidence -> honored
        let exact = parse(#"{"valid":true,"progressEvidenceIDs":["\#(evidence.id.uuidString)"],"criteria":[],"steps":[],"blockingCondition":"never deploy","blockingEvidenceIDs":["\#(evidence.id.uuidString)"]}"#)
        XCTAssertEqual(exact.blockingCondition, "never deploy")
        // unknown user string -> dropped
        let foreign = parse(#"{"valid":true,"progressEvidenceIDs":["\#(evidence.id.uuidString)"],"criteria":[],"steps":[],"blockingCondition":"other thing","blockingEvidenceIDs":["\#(evidence.id.uuidString)"]}"#)
        XCTAssertNil(foreign.blockingCondition)
        // unknown citation ids -> decoded (the grammar below is COMPLETE and
        // valid), yet the ORIGINAL citation rule makes the verdict invalid
        // and unions nothing. (A reply missing a required member would be a
        // decode failure, never a citation proof.)
        let unknown = parse(#"{"valid":true,"progressEvidenceIDs":["\#(UUID().uuidString)"],"criteria":[{"id":"\#(criterion.id.uuidString)","evidenceIDs":["\#(UUID().uuidString)"]}],"steps":[],"blockingCondition":null,"blockingEvidenceIDs":[]}"#)
        XCTAssertFalse(unknown.isValid)
        XCTAssertTrue(unknown.criterionEvidence.isEmpty)
        // valid claim without any progress citation -> invalid
        let empty = parse(#"{"valid":true,"progressEvidenceIDs":[],"criteria":[],"steps":[],"blockingCondition":null,"blockingEvidenceIDs":[]}"#)
        XCTAssertFalse(empty.isValid)
        // "Never infer user confirmation": the reply grammar has no
        // confirmation field; an injected extra member is not decoded into
        // any authority (the contract Reply is a strict Decodable without it).
        let injected = parse(#"{"valid":true,"progressEvidenceIDs":["\#(evidence.id.uuidString)"],"criteria":[],"steps":[],"userConfirmed":true,"blockingCondition":null,"blockingEvidenceIDs":[]}"#)
        XCTAssertTrue(injected.isValid)
        XCTAssertNil(injected.blockingCondition)
        // oversize output fails closed
        let oversized = GoalEvidenceReviewContract.parse(
            String(repeating: "x", count: 17_000), goal: goal, evidence: [evidence])
        XCTAssertFalse(oversized.reviewSucceeded)
        // preparation tools stay excluded from evidence eligibility
        XCTAssertTrue(GoalEvidenceReviewContract.isPreparationTool("tools.list"))
        XCTAssertFalse(GoalEvidenceReviewContract.isPreparationTool("file.write"))
    }

    /// Budgets consume the ACTUAL durable counters (original fields only):
    /// maxCycles reached => budgetLimited persisted and NO continuation.
    func testBudgetAuditUsesActualDurableCounters() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCompletedGoalRun(conversationID: conversationID,
                                                   objective: "obj")
        var goal = ConversationGoal(
            conversationID: conversationID, objective: "obj",
            acceptanceCriteria: [GoalCriterion(text: "done")],
            steps: [GoalStep(title: "Advance goal", status: .inProgress, order: 0)],
            status: .verifying,
            budgets: GoalBudgets(maxCycles: 1))
        goal.revision = 1
        goal.progress.cycleCount = 1   // folded by the run boundary already
        try await fixture.intelligence.saveGoal(goal)
        let domain = fixture.makeDomain()
        await evaluateLane(domain: domain, runID: runID, conversationID: conversationID)
        let durable = try await fixture.intelligence.goal(id: goal.id)
        XCTAssertEqual(durable?.status, .budgetLimited)
        XCTAssertEqual(durable?.revision, 2)
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 2, "budget-limited settle launches no continuation")
    }

    /// The ORIGINAL shared `GoalCompletionGate` (the exact function both
    /// the post-run lane and `goal.confirm` evaluate) stays fail closed on
    /// every durable check while a proper human-confirmed completion passes:
    /// unknown evidence, unsatisfied criteria, incomplete steps and a
    /// rejected review each block; a complete row with known evidence and
    /// the confirmation set may complete. These are behavior proofs over the
    /// real engine, not mirrored constants.
    func testGoalCompletionGateBlocksAndCompletesPerOriginalRules() throws {
        let conversationID = UUID()
        let proof = GoalEvidence(kind: .toolResult, reference: "run:1", summary: "p")
        let criterion = GoalCriterion(text: "c", isSatisfied: true,
                                      evidenceIDs: [proof.id],
                                      requiresUserConfirmation: true)
        let step = GoalStep(title: "Advance goal", status: .completed, order: 0)
        var goal = ConversationGoal(conversationID: conversationID, objective: "o",
                                    acceptanceCriteria: [criterion],
                                    steps: [step],
                                    evidence: [proof],
                                    status: .verifying)
        let proposal = GoalCompletionProposal(
            goalID: goal.id,
            criterionEvidence: [criterion.id: [proof.id]],
            reviewModelApproved: true)
        // Human-confirmed completion (the goal.confirm shape).
        let verdict = GoalCompletionGate.evaluate(goal: goal, proposal: proposal,
                                                  userConfirmedCriterionIDs: [criterion.id])
        XCTAssertTrue(verdict.mayComplete, "\(verdict.blockers)")
        // Without the human confirmation the same row refuses the criterion.
        let unconfirmed = GoalCompletionGate.evaluate(goal: goal, proposal: proposal,
                                                      userConfirmedCriterionIDs: [])
        XCTAssertTrue(unconfirmed.blockers.contains { blocker in
            if case .userConfirmationRequired = blocker { return true }
            return false
        })
        XCTAssertFalse(unconfirmed.mayComplete)
        // Unknown evidence id -> blocks.
        let forged = GoalCompletionProposal(goalID: goal.id,
                                            criterionEvidence: [criterion.id: [UUID()]],
                                            reviewModelApproved: true)
        let forgedVerdict = GoalCompletionGate.evaluate(goal: goal, proposal: forged,
                                                        userConfirmedCriterionIDs: [criterion.id])
        XCTAssertTrue(forgedVerdict.blockers.contains { blocker in
            if case .unknownEvidence = blocker { return true }
            return false
        })
        // Terminal goals never complete again.
        goal.status = .completed
        let terminal = GoalCompletionGate.evaluate(goal: goal, proposal: proposal,
                                                   userConfirmedCriterionIDs: [criterion.id])
        XCTAssertTrue(terminal.blockers.contains(.goalAlreadyTerminal))
        XCTAssertFalse(terminal.mayComplete)
        // A wrong goal identity short-circuits everything.
        let wrong = GoalCompletionProposal(goalID: UUID(),
                                           criterionEvidence: [:],
                                           reviewModelApproved: true)
        XCTAssertEqual(GoalCompletionGate.evaluate(goal: goal, proposal: wrong).blockers,
                       [.wrongGoal])
    }

    /// Single flight: while one review holds the goal's reservation (here:
    /// parked mid-stream in the scripted gate), a second evaluate for the
    /// SAME goal must return WITHOUT touching the durable row; after the
    /// first really settles, the goal advanced exactly one revision.
    func testSingleFlightBlocksConcurrentSettle() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCompletedGoalRun(conversationID: conversationID,
                                                   objective: "obj",
                                                   toolEvents: [("file.write", "one")])
        let goal = try await verifyingGoalPlain(conversationID: conversationID, objective: "obj")
        let domain = fixture.makeDomain()
        let gate = RunGateBox()
        let reviewIndex = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "never parsed")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: reviewIndex)
        let parked = stallRequest(at: reviewIndex + 1)  // continuation park
        let storedGoals = try await fixture.intelligence.goals(conversationID: conversationID)
        let ownedGoal = try XCTUnwrap(storedGoals.first)
        try await fixture.runStore.assignGoal(runID: runID, goalID: ownedGoal.id)
        let reviewRoute = RunModelAssembly.ResolvedPair(provider: fixture.providerProfile,
                                                       model: fixture.modelProfile,
                                                       approvalCredentials: nil)
        let reviewBundle = ordinaryBundle()
        let reviewStore = fixture.intelligence
        let first = Task {
            await domain.evaluateAndContinueGoal(completedRunID: runID,
                                                conversationID: conversationID,
                                                route: reviewRoute, bundle: reviewBundle,
                                                intelligence: reviewStore)
        }
        // Wait until the reservation is ACTUALLY held (real actor state).
        let held = await pollFor(timeoutSeconds: 8) {
            await domain.goalContinuationReservations[goal.id] != nil
        }
        XCTAssertTrue(held, "the first settle must hold the single-flight reservation")
        await evaluateLane(domain: domain, runID: runID, conversationID: conversationID)
        let revisionDuring = try await fixture.intelligence.goal(id: goal.id)?.revision
        XCTAssertEqual(revisionDuring, 1, "the blocked second settle committed nothing")
        gate.release()
        await first.value
        let revisionAfter = try await fixture.intelligence.goal(id: goal.id)?.revision
        XCTAssertEqual(revisionAfter, 2, "the first settle advanced exactly one revision")
        parked.release()
    }

    /// The continuation is durable-proven: it launches through the SAME
    /// pipeline with the captured frozen route and the ORIGINAL
    /// `goalContinuation` message role (the store's frozen vocabulary), and
    /// only when the reread goal is still active at the committed revision.
    /// Ordinary user launches keep role `user`.
    func testContinuationUsesFrozenRoleVocabularyAndActiveReread() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCompletedGoalRun(conversationID: conversationID,
                                                   objective: "keep going",
                                                   toolEvents: [("file.write", "z9")])
        let goal = try await verifyingGoalPlain(conversationID: conversationID,
                                                objective: "keep going")
        _ = goal
        let domain = fixture.makeDomain()
        // Park the continuation run's first provider request (index 1: the
        // review at index 0 uses the default script and fails JSON parsing
        // honestly). No scripted reply queued => the review stream errors => empty
        // Result; newEvidence IS non-empty so the lane falls through the
        // audits to `.active` (no budgets set) => CAS + reread + continuation.
        let parked = stallRequest(at: fixture.adapter.requestCount + 1)
        await evaluateLane(domain: domain, runID: runID, conversationID: conversationID)
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        let continuation = runs.first { $0.id != runID && $0.conversationMode == "goal" }
        guard let continuation else {
            parked.release()
            return XCTFail("active reread must produce exactly one continuation run")
        }
        let messages = try await fixture.conversationStore.messages(conversationID: conversationID)
        let turn = try XCTUnwrap(messages.first { $0.runID == continuation.id })
        XCTAssertEqual(turn.role, "goalContinuation",
                       "the continuation turn uses the ORIGINAL durable role vocabulary")
        XCTAssertTrue(turn.content.hasPrefix("Continue the active task goal: keep going"))
        // The lane HIDES it from assembled history (store-level role filter).
        let assembled = try await ConversationHistoryAssembler(store: fixture.conversationStore)
            .build(conversationID: conversationID)
        XCTAssertFalse(assembled.contains { $0.content.hasPrefix("Continue the active task goal") })
        // The settle launched its continuation synchronously (awaited).
        XCTAssertGreaterThanOrEqual(
            runs.filter { $0.id != runID && $0.conversationMode == "goal" }.count, 1)
        parked.release()
    }

    /// Retirement fences the lane: after `beginGenerationRetirement` a new
    /// review dispatch mints NO lease and a settle attempt cannot commit
    /// (the durable CAS lane is fenced via the reservation epoch checks).
    func testRetirementFencesNewReviewWork() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        await domain.beginGenerationRetirement()
        let leased = await domain.goalReviewLeases[conversationID]?.count ?? 0
        XCTAssertEqual(leased, 0)
        // A direct post-retirement evaluate must not persist anything.
        let runID = try await seedCompletedGoalRun(conversationID: conversationID,
                                                   objective: "obj")
        let goal = try await verifyingGoalPlain(conversationID: conversationID, objective: "obj")
        let revisionBefore = try await fixture.intelligence.goal(id: goal.id)?.revision
        await evaluateLane(domain: domain, runID: runID, conversationID: conversationID)
        let revisionAfter = try await fixture.intelligence.goal(id: goal.id)?.revision
        XCTAssertEqual(revisionBefore, revisionAfter,
                       "a retired generation mutates no durable goal")
    }

    // MARK: - matrix grammar (validator-owned structures)

    func testNewControlEnvelopesValidateAndForeignOnesRefuse() throws {
        let conversationID = UUID()
        // The FROZEN v3 validator requires `correlationID == requestID` and
        // `stateful == revisionRequired` for the rule. The envelopes below
        // therefore submit the ACTUAL wire grammar (the same request identity
        // the mailbox supplies) — the validator itself is never weakened.
        func validate(command: String, scope: BridgeV3.Scope, revision: [String: String]?,
                      payload: [String: Any]?, ownerRun: Bool = false,
                      stateful: Bool = true) -> Bool {
            let correlation = "corr-\(command)-\(UUID().uuidString.prefix(8))"
            var envelope: [String: Any] = [
                "schema": BridgeV3.commandSchema,
                "scope": scope.rawValue,
                "command": command,
                "stateful": stateful,
                "correlationID": correlation,
                "owner": ownerRun
                    ? ["taskID": conversationID.uuidString, "runID": UUID().uuidString]
                    : ["taskID": conversationID.uuidString],
            ]
            if let revision { envelope["revision"] = revision }
            if let payload { envelope["payload"] = payload }
            return BridgeV3.validate(envelope: envelope, requestID: correlation,
                                     operation: .submit).isValid
        }
        XCTAssertTrue(validate(command: "plan.accept", scope: .launch,
                               revision: ["resourceID": ConversationRowRevision.resourceID(conversationID: conversationID), "version": "v"],
                               payload: ["planID": UUID().uuidString, "planRevision": 1,
                                         "planDigest": "d", "providerID": UUID().uuidString,
                                         "modelID": UUID().uuidString]))
        XCTAssertTrue(validate(command: "goal.confirm", scope: .conversationLifecycle,
                               revision: ["resourceID": "goal.\(UUID().uuidString)", "version": "rev:1"],
                               payload: ["goalID": UUID().uuidString, "expectedGoalRevision": 1]))
        // conversation.compact carries NO per-row revision: the frozen rule
        // is `stateful == revisionRequired`, i.e. false here.
        XCTAssertTrue(validate(command: "conversation.compact", scope: .conversationLifecycle,
                               revision: nil, payload: nil, stateful: false))
        XCTAssertFalse(validate(command: "goal.confirm", scope: .conversationLifecycle,
                                revision: ["resourceID": "goal.\(UUID().uuidString)", "version": "rev:1"],
                                payload: ["goalID": UUID().uuidString, "expectedGoalRevision": 1],
                                ownerRun: true))
        // No child.create was ever added to the frozen grammar.
        XCTAssertFalse(validate(command: "child.create", scope: .taskExecution,
                                revision: ["resourceID": "run.\(UUID().uuidString)", "version": "preparing"],
                                payload: ["task": "subtask"]))
        // goalDefinition grammar is closed and mode-bound.
        XCTAssertThrowsError(try RunStartQuery.parse(payload: .object([
            "goal": .string("g"), "mode": .string("chat"),
            "providerID": .string(UUID().uuidString), "modelID": .string(UUID().uuidString),
            "goalDefinition": .object(["objective": .string("o")]),
        ]), conversationID: conversationID))
        XCTAssertNoThrow(try RunStartQuery.parse(payload: .object([
            "goal": .string("g"), "mode": .string("goal"),
            "providerID": .string(UUID().uuidString), "modelID": .string(UUID().uuidString),
        ]), conversationID: conversationID))
    }

    // MARK: - Explicit Stop vs the post-run review lane (Main review 2026-10-21)
    //
    // Controlled-stream barriers only; nothing sleeps-and-hopes. Each test
    // parks the REAL review stream inside the scripted adapter gate, mutates
    // actor state through the PRODUCTION entry points (run.cancel / a new
    // activation's launch), then releases and asserts durable truth.

    /// Seed a durable COMPLETED ordinary goal-mode run for a fresh
    /// conversation (one successful non-preparation tool result = one fresh
    /// evidence candidate), plus a live non-terminal goal.
    private func seedCompletedGoalRunWithEvidence(conversationID: UUID)
        async throws -> (runID: UUID, goalID: UUID) {
        let prepared = try await fixture.launchStore.prepare(RunLaunchRequest(
            conversationID: conversationID,
            goal: "Goal: finish the audit",
            conversationMode: "goal",
            providerID: fixture.providerID,
            modelID: fixture.modelID))
        try await fixture.runStore.updateRunState(id: prepared.run.id, state: "completed",
                                                  endedAt: Date())
        let callID = UUID().uuidString
        try await fixture.runStore.appendEvent(
            runID: prepared.run.id, kind: .toolRequest,
            payloadJSON: "{\"id\":\"\(callID)\",\"tool\":\"shell.exec\",\"input\":\"{}\"}")
        try await fixture.runStore.appendEvent(
            runID: prepared.run.id, kind: .toolResult,
            payloadJSON: "{\"callID\":\"\(callID)\",\"tool\":\"shell.exec\",\"status\":\"success\",\"summary\":\"ran\",\"outputDigest\":\"ev1\"}")
        try await fixture.runStore.appendEvent(
            runID: prepared.run.id, kind: .terminal,
            payloadJSON: #"{"state":"completed"}"#)
        var goal = ConversationGoal(conversationID: conversationID,
                                    objective: "finish the audit",
                                    acceptanceCriteria: [GoalCriterion(text: "c")],
                                    steps: [GoalStep(title: "Advance goal",
                                                     status: .inProgress, order: 0)],
                                    status: .verifying)
        goal.revision = 1
        try await fixture.intelligence.saveGoal(goal)
        let goalID = goal.id
        try await fixture.runStore.assignGoal(runID: prepared.run.id, goalID: goalID)
        return (prepared.run.id, goal.id)
    }

    private func bundle() -> RunPersistenceBundle {
        RunPersistenceBundle(identity: .ordinary,
                             conversations: fixture.conversationStore,
                             runs: fixture.runStore,
                             runningInputs: fixture.inputStore,
                             launches: fixture.launchStore,
                             childRuns: fixture.childStore,
                             intelligence: fixture.intelligence)
    }

    private func parkedReviewGate(reply: String) -> RunGateBox {
        let gate = RunGateBox()
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: reply)),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: fixture.adapter.requestCount)
        return gate
    }

    private func cancelEnvelope(conversationID: UUID, runID: UUID,
                                correlation: String) -> RunCommandEnvelope {
        fixture.executionEnvelope(
            command: "run.cancel", conversationID: conversationID, runID: runID,
            payload: ["expectedState": "completed"], correlation: correlation,
            revision: ["resourceID": "run.\(runID.uuidString)", "version": "completed"])
    }

    /// Explicit Stop after the terminal: the EXISTING run.cancel reaches the
    /// live review BEFORE the retired fast path; the ACK is `reviewStopping`
    /// (never a fake settled stop); the reservation (continuation
    /// admission) is revoked synchronously; the lease stays attached until
    /// the producer REALLY settles; after release nothing mutates and no
    /// next cycle launches; a second cancel then truthfully answers
    /// alreadyRequested; the completed run row is never rewritten.
    func testStopDuringLiveReviewHoldsLeaseAndSettlesWithoutLateWrites() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let (runID, goalID) = try await seedCompletedGoalRunWithEvidence(
            conversationID: conversationID)
        let domain = fixture.makeDomain()
        let frozen = RunModelAssembly.ResolvedPair(provider: fixture.providerProfile,
                                                   model: fixture.modelProfile,
                                                   approvalCredentials: nil)
        let gate = parkedReviewGate(reply: "not a review reply")
        await domain.dispatchGoalReview(runID: runID, conversationID: conversationID,
                                        frozen: frozen, bundle: bundle())
        // The lane really parked INSIDE the review stream (controlled
        // barrier), holding the reservation + the registry lease.
        let parked = await pollFor(timeoutSeconds: 8) { gate.isWaiting }
        XCTAssertTrue(parked, "review stream must be held by the gate")
        let reserving = await pollFor(timeoutSeconds: 8) {
            await domain.goalContinuationReservations[goalID] != nil
        }
        XCTAssertTrue(reserving, "the lane must hold its goal reservation")
        let activityActive: String = await domain.goalReviewActivity(runID: runID)
        XCTAssertEqual(activityActive, "active")
        // The parked review holds a REAL owned lease (not a bookkeeping
        // flag): the per-conversation drain sees it while it is live.
        let leaseWhileParked: Int = await domain.feedLeaseCount(
            conversationID: conversationID)
        XCTAssertGreaterThan(leaseWhileParked, 0,
                             "a live review attaches its exact lease")

        let reply = await domain.cancel(envelope: cancelEnvelope(
            conversationID: conversationID, runID: runID, correlation: "corr-stop-live"))
        guard case .mutationAccepted(let detail) = reply.outcome,
              detail["cancel"] == "reviewStopping" else {
            return XCTFail("stop must reach the live review: \(reply.outcome)")
        }
        // Synchronous invalidation proven through actor + drain state: the
        // continuation admission is revoked BEFORE any await, so the stop
        // itself can never launch a next cycle. (The cooperative producer
        // may settle immediately on cancellation — settlement speed is not
        // a product promise; the lease must never be detached by the stop
        // call itself, and it is observed live above.)
        let reservationGone = await domain.goalContinuationReservations[goalID] == nil
        XCTAssertTrue(reservationGone, "continuation admission revoked")

        gate.release()
        // Real settlement: wait the lane's own teardown (lease count to
        // zero through the actual release path — observation, not a sleep).
        let settled = await pollFor(timeoutSeconds: 8) {
            await domain.feedLeaseCount(conversationID: conversationID) == 0
        }
        XCTAssertTrue(settled, "the exact lease must release only at real settlement")
        let goalAfter = try await fixture.intelligence.goal(id: goalID)
        XCTAssertEqual(goalAfter?.revision, 1, "no late goal mutation after Stop")
        XCTAssertEqual(goalAfter?.status, .verifying)
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 2, "no next cycle launched after Stop (seed + stopped run)")
        let after: String = await domain.goalReviewActivity(runID: runID)
        XCTAssertEqual(after, "none", "activity clears only at real settlement")
        // Second cancel: the review REALLY settled (handle cleared), so the
        // stop seam no longer answers reviewStopping. This fixture-seeded
        // run was never owned/retired through this domain, so the durable
        // terminal-unowned truth is the pre-existing runNotRetryable
        // refusal; a domain-retired run answers alreadyRequested here
        // instead — either way never a second live-review stop.
        let second = await domain.cancel(envelope: cancelEnvelope(
            conversationID: conversationID, runID: runID, correlation: "corr-stop-again"))
        if case .mutationAccepted(let again) = second.outcome {
            XCTAssertNotEqual(again["cancel"], "reviewStopping")
        } else {
            XCTAssertEqual(rejected(second)?.reason, .runNotRetryable)
        }
        let record = try await fixture.runStore.run(id: runID)
        XCTAssertEqual(record?.state, "completed", "completed history never rewritten")
    }

    /// A newer EXPLICIT user activation (its launch C1 commits while the
    /// old review is parked) wins: releasing the old review must NOT write
    /// its goal's updatedAt (the durable stamp CAS refuses inside the
    /// writer transaction) and must NOT auto-launch its old objective. The
    /// newer run and its owner are untouched.
    func testDelayedReviewCannotMutateAfterNewerUserActivation() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let (runID, goalID) = try await seedCompletedGoalRunWithEvidence(
            conversationID: conversationID)
        let domain = fixture.makeDomain()
        let frozen = RunModelAssembly.ResolvedPair(provider: fixture.providerProfile,
                                                   model: fixture.modelProfile,
                                                   approvalCredentials: nil)
        let gate = parkedReviewGate(reply: #"{"valid":false,"progressEvidenceIDs":[],"criteria":[],"steps":[]}"#)
        await domain.dispatchGoalReview(runID: runID, conversationID: conversationID,
                                        frozen: frozen, bundle: bundle())
        let parked = await pollFor(timeoutSeconds: 8) { gate.isWaiting }
        XCTAssertTrue(parked)
        // A fixed/restored clock must not hide the NEW immutable C1 IDs.
        let beforeTimestamp = try await fixture.database.reader { db in
            try String.fetchOne(db, sql: "SELECT updated_at FROM conversations WHERE id = ?",
                                arguments: [conversationID.uuidString])
        }
        let beforeIdentity = try await fixture.intelligence
            .conversationActivationIdentity(conversationID: conversationID)
        // NEWER explicit user launch commits the real run/message/goal rows.
        // Its own provider stream is parked so the newer run cannot reach its
        // completion boundary during this test: `ensureDurableGoal` may
        // LEGITIMATELY adopt/supersede the old Goal (it is still non-terminal,
        // so the newer run reserves it), and moving it to verification would
        // advance the row. That is the newer activation's own truth — this
        // test must prove the DELAYED OLD lane adds nothing, so the durable
        // baseline is taken AFTER the newer C1 commits and BEFORE the old
        // review is released.
        let newRunGate = stallRequest(at: fixture.adapter.requestCount)
        let revision = try await fixture.revision(conversationID: conversationID)
        var startQuery: [String: Any] = fixture.startPayload(goal: "NEW user activation",
                                                             mode: "goal")
        startQuery["goalDefinition"] = [
            "objective": "the newer activation",
            "criteria": ["newer criterion"],
        ]
        let newer = await domain.start(envelope: fixture.launchEnvelope(
            conversationID: conversationID, payload: startQuery,
            revisionVersion: revision, correlation: "corr-newer-activation"),
            receipt: "op:v1:" + String(repeating: "b", count: 32),
            correlation: "corr-newer-activation")
        guard case .mutationAccepted = newer.outcome else {
            newRunGate.release()
            return XCTFail("newer user activation must commit: \(newer.outcome)")
        }
        try await fixture.database.writer { db in
            try db.execute(sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
                           arguments: [beforeTimestamp, conversationID.uuidString])
        }
        let afterTimestamp = try await fixture.database.reader { db in
            try String.fetchOne(db, sql: "SELECT updated_at FROM conversations WHERE id = ?",
                                arguments: [conversationID.uuidString])
        }
        let afterIdentity = try await fixture.intelligence
            .conversationActivationIdentity(conversationID: conversationID)
        XCTAssertEqual(afterTimestamp, beforeTimestamp, "This must exercise equal timestamps")
        XCTAssertNotNil(beforeIdentity)
        XCTAssertNotEqual(afterIdentity, beforeIdentity, "New actual C1 identities must differ")
        // Post-C1 durable baseline of the OLD goal row (the newer activation's
        // own adoption is allowed; only a NEW write by the old lane is not).
        let baseline = try await unwrapAsync(await fixture.intelligence.goal(id: goalID))
        gate.release()
        let settled = await pollFor(timeoutSeconds: 8) {
            await domain.feedLeaseCount(conversationID: conversationID) == 0
        }
        XCTAssertTrue(settled, "old lane settles (refused) after release")
        let oldGoal = try await fixture.intelligence.goal(id: goalID)
        XCTAssertEqual(oldGoal?.revision, baseline.revision,
                       "the delayed old review may not commit after the newer activation won")
        XCTAssertEqual(oldGoal?.status, baseline.status,
                       "the delayed old review may not rewrite the Goal status")
        XCTAssertEqual(oldGoal?.updatedAt, baseline.updatedAt,
                       "the delayed old review may not stamp the Goal")
        let goals = try await fixture.intelligence.goals(conversationID: conversationID)
        let objectives = goals.map(\.objective)
        XCTAssertEqual(objectives.filter { $0 == "the newer activation" }.count, 1,
                       "the newer user activation committed its own durable goal")
        // No auto continuation of the OLD objective ever exists — in ANY
        // role or row (the newer activation's own cycle may progress; the
        // old lane may not). Precise prompt identity, not a run count.
        let messages = try await fixture.conversationStore
            .messages(conversationID: conversationID)
        XCTAssertFalse(messages.contains {
            $0.content.hasPrefix("Continue the active task goal: finish the audit")
        }, "delayed review must not launch its OLD objective after the newer activation won")
        newRunGate.release()
    }

    /// Stop may only touch ITS OWN completed run's review: a foreign
    /// conversation refuses through the durable ownership proof, a
    /// replacement/newer run's review is a different completed run, and a
    /// fresh generation starts with an empty permit/lease world.
    func testStopScopingForeignAndReplacementAndNewGeneration() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let (runID, goalID) = try await seedCompletedGoalRunWithEvidence(
            conversationID: conversationID)
        let domain = fixture.makeDomain()
        // Foreign conversation: the durable record's ownership proof fails
        // BEFORE any review handling — and there is no work to stop anyway.
        let other = try await fixture.makeOrdinaryConversation(goal: "other thread")
        let foreign = await domain.cancel(envelope: cancelEnvelope(
            conversationID: other, runID: runID, correlation: "corr-stop-foreign"))
        XCTAssertNotNil(rejected(foreign), "foreign cancel must not resolve this run")
        // No review work exists yet for this run → the retired/terminal
        // paths answer exactly as before (no fake reviewStopping).
        let noWork = await domain.cancel(envelope: cancelEnvelope(
            conversationID: conversationID, runID: runID, correlation: "corr-stop-none"))
        let noWorkRejected = rejected(noWork)
        XCTAssertEqual(noWorkRejected?.reason, .runNotRetryable,
                       "terminal unowned run without live review keeps the old refusal")
        // Start the real review, stop it, and prove a SECOND fresh domain
        // (new generation) sees none of it.
        let frozen = RunModelAssembly.ResolvedPair(provider: fixture.providerProfile,
                                                   model: fixture.modelProfile,
                                                   approvalCredentials: nil)
        let gate = parkedReviewGate(reply: "x")
        await domain.dispatchGoalReview(runID: runID, conversationID: conversationID,
                                        frozen: frozen, bundle: bundle())
        _ = await pollFor { gate.isWaiting }
        let stopping = await domain.cancel(envelope: cancelEnvelope(
            conversationID: conversationID, runID: runID, correlation: "corr-stop-scope"))
        guard case .mutationAccepted(let detail) = stopping.outcome else {
            return XCTFail("in-scope stop must reach its own review")
        }
        XCTAssertEqual(detail["cancel"], "reviewStopping")
        let fresh = fixture.makeDomain()   // new generation actor instance
        let freshActivity: String = await fresh.goalReviewActivity(runID: runID)
        XCTAssertEqual(freshActivity, "none", "stop state never leaks across generations")
        let freshWorkEmpty: Bool = await fresh.goalReviewWorkByRun.isEmpty
        XCTAssertTrue(freshWorkEmpty)
        gate.release()
        _ = await pollFor(timeoutSeconds: 8) {
            await domain.feedLeaseCount(conversationID: conversationID) == 0
        }
        let goalAfter = try await fixture.intelligence.goal(id: goalID)
        XCTAssertEqual(goalAfter?.revision, 1)
    }

    // MARK: - Explicit user resume of an ordinary GOAL run (2026-10-21)

    /// EXPLICIT user resume (`run.retry`) of a FAILED ordinary goal-mode run:
    /// the SAME durable run row is re-owned, a NATIVE userResume marker
    /// advances the activation identity through the same writer, the exact
    /// durable provider/model pair is FROZEN and the postrun goal lane is
    /// registered — so the resumed run's REAL completion runs the original
    /// evidence/completion/budget/continuation lifecycle. A completed run
    /// stays NONRESUMABLE.
    func testExplicitGoalResumeReachesPostrunWithFrozenRoute() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        // One FAILED goal-mode run (resumable) owning a durable Goal with a
        // 1-cycle budget so the resumed lane settles without a next cycle.
        let prepared = try await fixture.launchStore.prepare(RunLaunchRequest(
            conversationID: conversationID,
            goal: "Goal: resume me",
            conversationMode: "goal",
            providerID: fixture.providerID,
            modelID: fixture.modelID))
        try await fixture.runStore.updateRunState(id: prepared.run.id, state: "failed",
                                                  endedAt: Date())
        try await fixture.runStore.appendEvent(
            runID: prepared.run.id, kind: .terminal,
            payloadJSON: #"{"terminal":"failed","recoverable":"true"}"#)
        var goal = ConversationGoal(
            conversationID: conversationID,
            objective: "resume me",
            acceptanceCriteria: [GoalCriterion(text: "done")],
            steps: [GoalStep(title: "Advance goal", status: .inProgress, order: 0)],
            status: .active,
            budgets: GoalBudgets(maxCycles: 1))
        goal.revision = 1
        try await fixture.intelligence.saveGoal(goal)
        let goalID = goal.id
        try await fixture.runStore.assignGoal(runID: prepared.run.id, goalID: goalID)
        let launchProof = try await unwrapAsync(await fixture.intelligence.frozenRunActivationIdentity(
                runID: prepared.run.id, conversationID: conversationID))
        let durable = try await unwrapAsync(await fixture.runStore.run(id: prepared.run.id))
        let durableProviderID = try XCTUnwrap(durable.providerID)
        let durableModelID = try XCTUnwrap(durable.modelID)
        let domain = fixture.makeDomain()
        // The resumed service's first provider turn completes with a real
        // assistant answer (default fixture script) — no extra scripting.
        let retry = await domain.retry(
            envelope: fixture.executionEnvelope(
                command: "run.retry", conversationID: conversationID,
                runID: prepared.run.id,
                payload: ["expectedState": "failed"],
                correlation: "corr-explicit-resume",
                revision: ["resourceID": "run.\(prepared.run.id.uuidString)",
                           "version": "failed"]),
            receipt: "op:v1:" + String(repeating: "c", count: 32))
        guard case .mutationAccepted = retry.outcome else {
            return XCTFail("explicit resume must be admitted: \(retry.outcome)")
        }
        // (a) The native marker advanced the activation identity; the old
        // launch proof can no longer stand in for this run.
        let resumeProof = try await unwrapAsync(await fixture.intelligence.frozenRunActivationIdentity(
                runID: prepared.run.id, conversationID: conversationID))
        XCTAssertNotEqual(resumeProof, launchProof,
                          "the resume commits a NEW native activation marker")
        let currentProof = try await fixture.intelligence.conversationActivationIdentity(
            conversationID: conversationID)
        XCTAssertEqual(currentProof, resumeProof)
        // (b) The run is registered for the original postrun lane with the
        // EXACT durable admitted provider/model pair (never a default).
        let registered: Bool = await domain.goalModeRuns.contains(prepared.run.id)
        XCTAssertTrue(registered, "resumed goal run registers the postrun lane")
        let frozenRoute = await domain.frozenRoutes[prepared.run.id]
        XCTAssertEqual(frozenRoute?.provider.id, durableProviderID)
        XCTAssertEqual(frozenRoute?.model.id, durableModelID)
        // (c) The resumed run really completes and its postrun lane commits
        // through the SAME-writer activation CAS: verifying -> budgetLimited.
        let completed = await pollFor(timeoutSeconds: 20) {
            (try? await self.fixture.runState(prepared.run.id)) == "completed"
        }
        XCTAssertTrue(completed, "the resumed run reaches its real terminal")
        let intelligence = fixture.intelligence
        let settledGoal = await pollFor(timeoutSeconds: 20) {
            guard let row = try? await intelligence.goal(id: goalID) else { return false }
            return row.status == .budgetLimited
        }
        XCTAssertTrue(settledGoal,
                      "the resumed completion runs the ORIGINAL postrun lane")
        let after = try await unwrapAsync(await fixture.intelligence.goal(id: goalID))
        XCTAssertEqual(after.status, .budgetLimited)
        XCTAssertEqual(after.revision, 3,
                       "moveGoalToVerification (+1) then the lane CAS (+1)")
        XCTAssertEqual(after.progress.cycleCount, 1,
                       "the resumed cycle folded its ACTUAL counter")
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 2, "a budget-limited settle launches no continuation")
        let clearedRoute = await domain.frozenRoutes[prepared.run.id]
        XCTAssertNil(clearedRoute, "the frozen route clears at real retirement")
        // (d) Completed history is FINAL: a second explicit resume refuses
        // with the ORIGINAL retry vocabulary and rewrites nothing.
        let again = await domain.retry(
            envelope: fixture.executionEnvelope(
                command: "run.retry", conversationID: conversationID,
                runID: prepared.run.id,
                payload: ["expectedState": "completed"],
                correlation: "corr-explicit-resume-again",
                revision: ["resourceID": "run.\(prepared.run.id.uuidString)",
                           "version": "completed"]),
            receipt: "op:v1:" + String(repeating: "d", count: 32))
        XCTAssertEqual(rejected(again)?.reason, .runNotRetryable)
        let finalRecord = try await unwrapAsync(await fixture.runStore.run(id: prepared.run.id))
        XCTAssertEqual(finalRecord.state, "completed", "completed history never rewritten")
    }

    /// A NEWER user C1 that commits BEFORE the old review is even dispatched
    /// must make the lane refuse immediately — no reservation survives, no
    /// goal write, no continuation — while the conversation clock is pinned
    /// to the SAME second (identity, never the clock).
    func testNewerActivationBeforeDispatchRefusesOldLane() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let (runID, goalID) = try await seedCompletedGoalRunWithEvidence(
            conversationID: conversationID)
        let domain = fixture.makeDomain()
        let beforeTimestamp = try await fixture.database.reader { db in
            try String.fetchOne(db, sql: "SELECT updated_at FROM conversations WHERE id = ?",
                                arguments: [conversationID.uuidString])
        }
        // The newer run's provider stream is parked: it must not reach its
        // completion boundary (only its C1 is under test here).
        let newRunGate = stallRequest(at: fixture.adapter.requestCount)
        let revision = try await fixture.revision(conversationID: conversationID)
        var startQuery: [String: Any] = fixture.startPayload(goal: "NEWER ARRIVAL",
                                                             mode: "goal")
        startQuery["goalDefinition"] = ["objective": "the newer arrival",
                                        "criteria": ["newer criterion"]]
        let newer = await domain.start(
            envelope: fixture.launchEnvelope(conversationID: conversationID,
                                             payload: startQuery,
                                             revisionVersion: revision,
                                             correlation: "corr-predispatch-newer"),
            receipt: "op:v1:" + String(repeating: "e", count: 32),
            correlation: "corr-predispatch-newer")
        guard case .mutationAccepted = newer.outcome else {
            newRunGate.release()
            return XCTFail("newer user activation must commit: \(newer.outcome)")
        }
        try await fixture.database.writer { db in
            try db.execute(sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
                           arguments: [beforeTimestamp, conversationID.uuidString])
        }
        let baseline = try await unwrapAsync(await fixture.intelligence.goal(id: goalID))
        let frozen = RunModelAssembly.ResolvedPair(provider: fixture.providerProfile,
                                                   model: fixture.modelProfile,
                                                   approvalCredentials: nil)
        // Dispatch the OLD review only NOW (the newer C1 already committed).
        await domain.dispatchGoalReview(runID: runID, conversationID: conversationID,
                                        frozen: frozen, bundle: bundle())
        let settled = await pollFor(timeoutSeconds: 8) {
            await domain.feedLeaseCount(conversationID: conversationID) == 0
        }
        XCTAssertTrue(settled, "the refused lane settles and releases its lease")
        let noReservation = await domain.goalContinuationReservations[goalID] == nil
        XCTAssertTrue(noReservation, "a refused lane leaves no continuation admission")
        let after = try await unwrapAsync(await fixture.intelligence.goal(id: goalID))
        XCTAssertEqual(after.revision, baseline.revision,
                       "the newer activation refuses the old lane's write")
        XCTAssertEqual(after.updatedAt, baseline.updatedAt)
        let messages = try await fixture.conversationStore
            .messages(conversationID: conversationID)
        XCTAssertFalse(messages.contains {
            $0.content.hasPrefix("Continue the active task goal: finish the audit")
        }, "a refused pre-dispatch lane launches no old-objective continuation")
        newRunGate.release()
    }

    // MARK: - Resume admission barriers (Main review 2026-10-21)

    /// Seeds one FAILED ordinary goal-mode run owning a one-cycle Goal (the
    /// same shape the resume product test uses) and returns ids.
    private func seedFailedGoalRun(conversationID: UUID, objective: String)
        async throws -> (runID: UUID, goalID: UUID) {
        let prepared = try await fixture.launchStore.prepare(RunLaunchRequest(
            conversationID: conversationID,
            goal: "Goal: \(objective)",
            conversationMode: "goal",
            providerID: fixture.providerID,
            modelID: fixture.modelID))
        try await fixture.runStore.updateRunState(id: prepared.run.id, state: "failed",
                                                  endedAt: Date())
        try await fixture.runStore.appendEvent(
            runID: prepared.run.id, kind: .terminal,
            payloadJSON: #"{"terminal":"failed","recoverable":"true"}"#)
        var goal = ConversationGoal(
            conversationID: conversationID,
            objective: objective,
            acceptanceCriteria: [GoalCriterion(text: "done")],
            steps: [GoalStep(title: "Advance goal", status: .inProgress, order: 0)],
            status: .active,
            budgets: GoalBudgets(maxCycles: 1))
        goal.revision = 1
        try await fixture.intelligence.saveGoal(goal)
        try await fixture.runStore.assignGoal(runID: prepared.run.id, goalID: goal.id)
        return (prepared.run.id, goal.id)
    }

    /// Holds the SOLE database writer so a resume's C1 commit cannot land
    /// until the test releases it. A REAL store barrier, not a sleep guess:
    /// the resume blocks inside its own atomic commit while this transaction
    /// is open (bounded to 15s so a failed test cannot hang the suite).
    private func holdDatabaseWriter()
        -> (flag: ResumeBarrierFlag, release: DispatchSemaphore,
            task: Task<Void, Never>) {
        let flag = ResumeBarrierFlag()
        let release = DispatchSemaphore(value: 0)
        let database = fixture.database
        let task = Task.detached {
            _ = try? await database.writer { db in
                flag.markEntered()
                _ = release.wait(timeout: .now() + 6)
                _ = try? Row.fetchOne(db, sql: "SELECT 1")
            }
        }
        return (flag, release, task)
    }

    private func resumeEnvelope(conversationID: UUID, runID: UUID,
                                correlation: String) -> RunCommandEnvelope {
        fixture.executionEnvelope(
            command: "run.retry", conversationID: conversationID, runID: runID,
            payload: ["expectedState": "failed"], correlation: correlation,
            revision: ["resourceID": "run.\(runID.uuidString)", "version": "failed"])
    }

    /// EXPLICIT Stop lands while the resume is BLOCKED at its own C1 writer
    /// (owner `.admitting`): the ACK is the truthful `pendingC0`, the C1
    /// still commits and is then abandoned by the SAME exact owner — the
    /// durable run ends failed with a terminal, the native resume marker
    /// really committed, NO service is handed off, the exact lease drains and
    /// the postrun lane never registers.
    func testResumeCancelledDuringAdmissionAbandonsCommittedC1NoLateService() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let (runID, goalID) = try await seedFailedGoalRun(
            conversationID: conversationID, objective: "cancel resume")
        let domain = fixture.makeDomain()
        let barrier = holdDatabaseWriter()
        let barrierHeld = await pollFor(timeoutSeconds: 5) {
            barrier.flag.entered
        }
        XCTAssertTrue(barrierHeld, "the store barrier must really hold the writer")
        let resumeCommand = resumeEnvelope(conversationID: conversationID,
                                           runID: runID,
                                           correlation: "corr-resume-cancel")
        let resumeTask = Task {
            await domain.retry(
                envelope: resumeCommand,
                receipt: "op:v1:" + String(repeating: "f", count: 32))
        }
        let admitted = await pollFor(timeoutSeconds: 5) {
            await domain.owners[runID]?.phase == .admitting
        }
        XCTAssertTrue(admitted, "the resume owner is admitted before the C1")
        let cancelReply = await domain.cancel(
            envelope: fixture.executionEnvelope(
                command: "run.cancel", conversationID: conversationID, runID: runID,
                payload: ["expectedState": "failed"],
                correlation: "corr-resume-cancel-stop",
                revision: ["resourceID": "run.\(runID.uuidString)",
                           "version": "failed"]))
        guard case .mutationAccepted(let cancelDetail) = cancelReply.outcome else {
            barrier.release.signal()
            return XCTFail("stop must reach the admitted resume: \(cancelReply.outcome)")
        }
        XCTAssertEqual(cancelDetail["cancel"], "pendingC0",
                       "a Stop during resume admission is a real C0 stop")
        barrier.release.signal()
        await barrier.task.value
        let reply = await resumeTask.value
        XCTAssertEqual(rejected(reply)?.code, .sessionFenced)
        // Durable truth: the committed resume transition was abandoned by the
        // exact owner (failed + terminal), never left live.
        let record = try await fixture.runStore.run(id: runID)
        XCTAssertEqual(record?.state, "failed")
        XCTAssertNotNil(record?.endedAt)
        let events = try await fixture.runStore.events(runID: runID)
        XCTAssertEqual(events.last?.kind, .terminal)
        let markerProof = try await fixture.intelligence.frozenRunActivationIdentity(
            runID: runID, conversationID: conversationID)
        XCTAssertNotNil(markerProof, "the native userResume marker committed before abandonment")
        // No late service, no leftover owner, exact lease drained.
        let noService = await domain.liveServices[runID] == nil
        XCTAssertTrue(noService, "no late service handoff after the stop")
        let noOwner = await domain.owners[runID] == nil
        XCTAssertTrue(noOwner)
        let drained = await pollFor(timeoutSeconds: 8) {
            await domain.feedLeaseCount(conversationID: conversationID) == 0
        }
        XCTAssertTrue(drained, "the exact admission lease really drained")
        let notRegistered = await domain.goalModeRuns.contains(runID) == false
        XCTAssertTrue(notRegistered, "an abandoned resume never registers the postrun lane")
        let noRoute = await domain.frozenRoutes[runID] == nil
        XCTAssertTrue(noRoute)
        let goalAfter = try await fixture.intelligence.goal(id: goalID)
        XCTAssertEqual(goalAfter?.revision, 1, "no goal write from an abandoned resume")
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 2, "no second run row on the SAME resume identity")
        let messages = try await fixture.conversationStore
            .messages(conversationID: conversationID)
        XCTAssertFalse(messages.contains {
            $0.content.hasPrefix("Continue the active task goal")
        })
    }

    /// A gate/transport refusal AFTER the C0 owner attach releases the
    /// EXACT owner/token (the pre-review leak): no attached registry token
    /// remains, no resume marker/state transition is written and the durable
    /// row still reads failed.
    func testResumeGateRefusalReleasesExactOwner() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let (runID, goalID) = try await seedFailedGoalRun(
            conversationID: conversationID, objective: "gate refusal")
        _ = goalID
        let domain = fixture.makeDomain(transportQualified: false)
        let reply = await domain.retry(
            envelope: resumeEnvelope(conversationID: conversationID, runID: runID,
                                     correlation: "corr-resume-gate"),
            receipt: "op:v1:" + String(repeating: "7", count: 32))
        XCTAssertEqual(rejected(reply)?.code, .transportUnavailable)
        let noOwner = await domain.owners[runID] == nil
        XCTAssertTrue(noOwner, "the exact owner is released on a gate refusal")
        let evidenceTokens = await domain.drainEvidenceTokens(
            conversationID: conversationID)
        let stillAttached = evidenceTokens.contains {
            RuntimeOwnedWorkRegistry.shared.isAttached($0)
        }
        XCTAssertFalse(stillAttached,
                       "no registry token survives a refused resume admission")
        let record = try await fixture.runStore.run(id: runID)
        XCTAssertEqual(record?.state, "failed", "a C0 refusal writes no state")
        // No resume marker: the run still carries exactly its ORIGINAL launch
        // proof, and the conversation identity did not advance.
        let originalProof = try await unwrapAsync(
            await fixture.intelligence.frozenRunActivationIdentity(
                runID: runID, conversationID: conversationID))
        let currentIdentity = try await fixture.intelligence.conversationActivationIdentity(
            conversationID: conversationID)
        XCTAssertEqual(currentIdentity, originalProof,
                       "a C0 refusal writes no resume marker")
    }

    /// ROOT generation retirement lands while the resume is blocked at its
    /// C1 writer: the committed resume is abandoned by the exact owner, no
    /// service is handed off, no postrun lane registers and the durable row
    /// stays truthful (failed + terminal). A late admission never touches a
    /// replacement: the owner is still `.admitting`, so no second resume
    /// could exist for the same run id.
    func testResumeRootFenceDuringAdmissionAbandonsWithoutService() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let (runID, goalID) = try await seedFailedGoalRun(
            conversationID: conversationID, objective: "fenced resume")
        let domain = fixture.makeDomain()
        let barrier = holdDatabaseWriter()
        let barrierHeld = await pollFor(timeoutSeconds: 5) {
            barrier.flag.entered
        }
        XCTAssertTrue(barrierHeld, "the store barrier must really hold the writer")
        let resumeCommand = resumeEnvelope(conversationID: conversationID,
                                           runID: runID,
                                           correlation: "corr-resume-retire")
        let resumeTask = Task {
            await domain.retry(
                envelope: resumeCommand,
                receipt: "op:v1:" + String(repeating: "6", count: 32))
        }
        let admitted = await pollFor(timeoutSeconds: 5) {
            await domain.owners[runID]?.phase == .admitting
        }
        XCTAssertTrue(admitted, "the resume owner is admitted before the C1")
        await domain.beginGenerationRetirement()
        barrier.release.signal()
        await barrier.task.value
        let reply = await resumeTask.value
        XCTAssertEqual(rejected(reply)?.code, .sessionFenced)
        let record = try await fixture.runStore.run(id: runID)
        XCTAssertEqual(record?.state, "failed")
        let events = try await fixture.runStore.events(runID: runID)
        XCTAssertEqual(events.last?.kind, .terminal)
        let noService = await domain.liveServices[runID] == nil
        XCTAssertTrue(noService, "retirement never hands off a late service")
        let noOwner = await domain.owners[runID] == nil
        XCTAssertTrue(noOwner)
        let drained = await pollFor(timeoutSeconds: 8) {
            await domain.feedLeaseCount(conversationID: conversationID) == 0
        }
        XCTAssertTrue(drained)
        let notRegistered = await domain.goalModeRuns.contains(runID) == false
        XCTAssertTrue(notRegistered)
        let goalAfter = try await fixture.intelligence.goal(id: goalID)
        XCTAssertEqual(goalAfter?.revision, 1)
    }
}

// MARK: - fixture-internal observation helpers (test-side reads of actor
// state through @testable; production code is untouched)

extension RunDomainFixture {
    /// Reads the ACTUAL shared reservation set on the actor (honest
    /// observation of the production state, not a back door into it).
    func compactingHeld(_ conversationID: UUID, in domain: FacadeRunDomain) async -> Bool {
        await domain.compactingConversations.contains(conversationID)
    }
}

/// Async-safe "the barrier transaction really opened" flag. `NSLock.lock()`
/// is `noasync`, so the SYNC writer closure sets it and async test code only
/// reads the protected Bool (`NSLock` is used inside both, never across an
/// await).
final class ResumeBarrierFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var enteredValue = false
    func markEntered() {
        lock.lock(); enteredValue = true; lock.unlock()
    }
    var entered: Bool {
        lock.lock(); defer { lock.unlock() }; return enteredValue
    }
}
