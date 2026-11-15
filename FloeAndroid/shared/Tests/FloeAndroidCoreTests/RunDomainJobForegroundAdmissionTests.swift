// SPDX-License-Identifier: MPL-2.0
//
// G03-R4 — the AUTOMATIC parked-run resume admission boundary
// (job-7b4afa8bc6784bce). AUTHORED, NOT EXECUTED here.
//
// Every fixture component is the REAL production code (original durable
// stores, run domain, ConversationRunService/FloeAgentRuntime); the model
// stream and the trusted-host foreground admission are the ONLY doubles.
// These tests assert the three gaps this batch closes:
//
//   1. a resumed run NEVER dispatches provider/tool work without a REAL
//      foreground admission, and a refusal leaves the parked data intact
//      and retryable;
//   2. a Stop that commits while the resume is still admitting/interleaving
//      wins atomically (no late provider turn, no false resumed claim);
//   3. a dependency settled while the parent is STILL LIVE is delivered
//      exactly once as native system lifecycle context — never as a human
//      turn, never as a second run.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
@testable import FloeAndroidCore

final class RunDomainJobForegroundAdmissionTests: XCTestCase {
    private var fixture: RunDomainFixture!

    override func setUp() async throws {
        fixture = try await RunDomainFixture.make()
    }

    override func tearDown() async throws {
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    // MARK: - Fixtures

    private struct Parked {
        var runID: UUID
        var conversationID: UUID
        var dependencies: SQLiteRunDependencyStore
        var jobID: UUID
    }

    private func components(
        foreground: any RunForegroundAdmissionPort
    ) -> RunDomainComponents {
        let base = fixture.components(foreground: foreground)
        let database = fixture.database
        var bound = base
        bound.runDependencyEdges = G02RunDependencyEdgeReader(database: database)
        bound.commitParkedRunStop = { runID, conversationID, expected in
            await G02ParkedRunStopCommitter(database: database).commit(
                runID: runID, conversationID: conversationID,
                expectedState: expected)
        }
        bound.cancelParkedRunJobs = { _, _, _ in [] }
        return bound
    }

    private func makeParkedRun(
        conversationID: UUID,
        jobID: UUID,
        edge: RunDependencyState = .resolved
    ) async throws -> Parked {
        let runID = UUID()
        let goal = "finish the required background work"
        try await fixture.runStore.saveRun(RunRecord(
            id: runID, conversationID: conversationID, state: "checkpointed",
            goal: goal, startedAt: Date().addingTimeInterval(-120),
            endedAt: Date(), providerID: fixture.providerID,
            modelID: fixture.modelID, conversationMode: "chat"))
        let checkpoint = AgentCheckpoint(
            runID: runID, conversationID: conversationID,
            state: .preparing(.init(goal: goal)),
            messages: [ConversationMessage(role: "user", content: goal)],
            schemaVersion: DatabaseManager.currentSchemaVersion)
        try await fixture.checkpoints.save(checkpoint)
        let reason = "awaiting.finite.job:" + jobID.uuidString
        let payload = try JSONSerialization.data(withJSONObject: [
            "state": "checkpointed", "reason": reason,
        ], options: [.sortedKeys])
        _ = try await fixture.runStore.appendEvent(
            runID: runID, kind: .status,
            payloadJSON: String(decoding: payload, as: UTF8.self))
        let dependencies = SQLiteRunDependencyStore(database: fixture.database)
        try await dependencies.register(RunDependencyRecord(
            jobID: jobID, runID: runID,
            conversationID: conversationID, kind: "job"))
        if edge != .pending {
            _ = try await dependencies.resolve(jobID: jobID, state: edge, note: nil)
        }
        return Parked(runID: runID, conversationID: conversationID,
                      dependencies: dependencies, jobID: jobID)
    }

    private func enqueueAnswer(_ text: String) -> Int {
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: text)),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: index)
        return index
    }

    // MARK: - Foreground refusal

    func testForegroundRefusalDispatchesNothingAndKeepsTheParkedTaskRetryable() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let parked = try await makeParkedRun(conversationID: conversationID,
                                             jobID: UUID())
        let foreground = RunForegroundAdmissionStub(decision: .refused)
        let domain = fixture.makeCustomDomain(components(foreground: foreground))
        let requestsBefore = fixture.adapter.requestCount
        _ = enqueueAnswer("the resumed turn")

        let refused = await domain.resumeAwaitingDependency(
            runID: parked.runID, conversationID: conversationID)
        XCTAssertEqual(refused, .foregroundUnavailable,
                       "a refused REAL admission is a typed refusal, not a resume")
        XCTAssertEqual(fixture.adapter.requestCount, requestsBefore,
                       "NO provider turn may start without real foreground protection")
        let refusedState = try await fixture.runState(parked.runID)
        XCTAssertEqual(refusedState, "checkpointed",
                       "the parked row is preserved exactly")
        let reason = await domain.durableCheckpointReason(runID: parked.runID)
        XCTAssertTrue(reason?.hasPrefix("awaiting.finite.job") == true,
                      "the dependency park cause is untouched")
        let edge = try await parked.dependencies.record(jobID: parked.jobID)
        XCTAssertEqual(edge?.state, .resolved, "the settled edge is untouched")
        let messages = try await fixture.conversationStore
            .messages(conversationID: conversationID)
        XCTAssertTrue(messages.filter { $0.runID == parked.runID }.isEmpty,
                      "a refused resume writes no lifecycle claim")
        XCTAssertEqual(foreground.admissions.count, 1,
                       "the handshake really asked the trusted host")
        let refusedOwnership = await domain.ownership(runID: parked.runID)
        XCTAssertNil(refusedOwnership, "a refused admission owns nothing")

        // An EXPLICIT later retry with a real admission continues the SAME
        // parked run (retryable, never a dead task).
        foreground.setDecision(.admitted)
        let resumed = await domain.resumeAwaitingDependency(
            runID: parked.runID, conversationID: conversationID)
        XCTAssertEqual(resumed, .resumed)
        let terminal = await waitDurableTerminal(fixture: fixture,
                                                 runID: parked.runID)
        XCTAssertEqual(terminal, "completed")
        let retriedAdmissions = foreground.admissions.filter {
            $0.runID == parked.runID
        }.count
        XCTAssertEqual(retriedAdmissions, 2)
        XCTAssertTrue(foreground.releases.isEmpty,
                      "a handed-off run keeps its lease until real settlement")
    }

    func testUnboundHostIsNeverTreatedAsAdmitted() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let parked = try await makeParkedRun(conversationID: conversationID,
                                             jobID: UUID())
        let foreground = RunForegroundAdmissionStub(decision: .unbound)
        let domain = fixture.makeCustomDomain(components(foreground: foreground))
        let requestsBefore = fixture.adapter.requestCount

        let result = await domain.resumeAwaitingDependency(
            runID: parked.runID, conversationID: conversationID)
        XCTAssertEqual(result, .foregroundUnavailable)
        XCTAssertEqual(fixture.adapter.requestCount, requestsBefore)
        let unboundState = try await fixture.runState(parked.runID)
        XCTAssertEqual(unboundState, "checkpointed")
    }

    // MARK: - Stop wins during admission

    func testStopCommittedDuringForegroundAdmissionWinsWithoutAProviderTurn() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let parked = try await makeParkedRun(conversationID: conversationID,
                                             jobID: UUID())
        let foreground = RunForegroundAdmissionStub(decision: .admitted)
        let domain = fixture.makeCustomDomain(components(foreground: foreground))
        let requestsBefore = fixture.adapter.requestCount
        _ = enqueueAnswer("must never be dispatched")
        // The Stop commits exactly where a real user Stop can: while the
        // automatic resume is awaiting the host's REAL foreground start and
        // BEFORE the durable resume CAS.
        let runID = parked.runID
        foreground.setOnAdmit { [weak domain] in
            _ = await domain?.stopAwaitingDependency(
                runID: runID, conversationID: conversationID)
        }

        let result = await domain.resumeAwaitingDependency(
            runID: parked.runID, conversationID: conversationID)
        XCTAssertEqual(result, .fenced,
                       "the resume must lose to a Stop that already committed")
        XCTAssertEqual(fixture.adapter.requestCount, requestsBefore,
                       "no provider turn after the user's Stop")
        let stoppedState = try await fixture.runState(parked.runID)
        XCTAssertEqual(stoppedState, "checkpointed")
        let reason = await domain.durableCheckpointReason(runID: parked.runID)
        XCTAssertEqual(reason, FacadeRunDomain.parkedUserStopReason,
                       "the durable cause is the user's Stop")
        let hasTerminal = try await fixture.hasTerminalEvent(parked.runID)
        XCTAssertFalse(hasTerminal, "the run is parked, not falsely completed")
        let stoppedOwnership = await domain.ownership(runID: parked.runID)
        XCTAssertNil(stoppedOwnership)
        XCTAssertEqual(foreground.releases.map { $0.runID }, [parked.runID],
                       "the abandoned admission releases its exact lease")
        // The late duplicate callback cannot revive the stopped run.
        let late = await domain.resumeAwaitingDependency(
            runID: parked.runID, conversationID: conversationID)
        XCTAssertEqual(late, .notAwaiting)
        XCTAssertEqual(fixture.adapter.requestCount, requestsBefore)
    }

    // MARK: - The committed-resume fence (pure, deterministic)

    func testResumeFenceVerdictsProveWhoWonTheRace() {
        let park = RunDependencyParkMarker(
            reason: "awaiting.finite.job:" + UUID().uuidString, sequence: 7)
        let resumeMarker = """
        {"floeActivation":{"kind":"userResume","proof":"p"},"state":"preparing"}
        """
        let stopRow = """
        {"floeActivation":{"kind":"userStop","version":1},"reason":"\
        \(FacadeRunDomain.parkedUserStopReason)","state":"checkpointed"}
        """
        func row(_ sequence: Int, _ kind: RunEventRecord.Kind,
                 _ payload: String) -> (sequence: Int, kind: RunEventRecord.Kind,
                                        payload: String) {
            (sequence: sequence, kind: kind, payload: payload)
        }

        XCTAssertEqual(RunDependencyResumeFence.verdict(
            park: park,
            eventsAfterPark: [row(8, .status, resumeMarker)]), .clean)
        XCTAssertEqual(RunDependencyResumeFence.verdict(
            park: park,
            eventsAfterPark: [row(8, .status, stopRow),
                              row(9, .status, resumeMarker)]), .userStopped,
            "a Stop row between the park and the resume marker wins")
        XCTAssertEqual(RunDependencyResumeFence.verdict(
            park: park,
            eventsAfterPark: [row(8, .status, resumeMarker),
                              row(9, .status, stopRow)]), .userStopped)
        XCTAssertEqual(RunDependencyResumeFence.verdict(
            park: park,
            eventsAfterPark: [row(8, .toolResult, "{}")]), .unreadable,
            "no status row after the park is never a clean resume")
        XCTAssertEqual(RunDependencyResumeFence.verdict(
            park: park,
            eventsAfterPark: [row(8, .status, "{\"state\":\"preparing\"}")]),
            .foreign, "an unproven status row is not the resume marker")
        XCTAssertEqual(RunDependencyResumeFence.verdict(
            park: park,
            eventsAfterPark: [row(8, .status, resumeMarker),
                              row(9, .status, resumeMarker)]), .foreign,
            "exactly ONE committed resume marker is admissible")
        XCTAssertEqual(RunDependencyResumeFence.verdict(
            park: park, eventsAfterPark: nil), .unreadable)
        XCTAssertEqual(RunDependencyResumeFence.verdict(
            park: park,
            eventsAfterPark: [row(6, .status, resumeMarker)]), .foreign,
            "a marker BEFORE the park sequence proves nothing")
    }

    // MARK: - Live parent lifecycle receipt

    func testSettledDependencyReachesTheLiveParentOnceAsSystemContext() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let foreground = RunForegroundAdmissionStub()
        let domain = fixture.makeCustomDomain(components(foreground: foreground))
        let jobID = UUID()
        // Round 1 stalls after its visible text; the settled job arrives while
        // this exact run is still live, before its final pending-edge check.
        let gate = RunGateBox()
        defer { gate.release() }
        let first = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "working on it")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: first)
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "the background work completed")),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: first + 1)
        let revision = try await fixture.revision(conversationID: conversationID)
        let started = await domain.start(
            envelope: fixture.launchEnvelope(
                conversationID: conversationID,
                payload: fixture.startPayload(goal: "run the background work"),
                revisionVersion: revision, correlation: "corr-live-notice"),
            receipt: "op:v1:" + String(repeating: "7", count: 32),
            correlation: "corr-live-notice")
        guard case .mutationAccepted(let detail) = started.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            gate.release()
            return XCTFail("launch must hand off")
        }
        let handedOff = await pollFor {
            await domain.ownership(runID: runID)?.phase == .handedOff
        }
        XCTAssertTrue(handedOff, "the live run must really hand off")
        let streaming = await pollFor {
            (try? await self.fixture.runState(runID)) == "streamingModel"
        }
        XCTAssertTrue(streaming, "the live run must really be streaming")
        // streamingModel is published before adapter admission. Capture the
        // original human turns only after the first REAL request is present.
        let requested = await pollFor { self.fixture.adapter.requestCount == first + 1 }
        XCTAssertTrue(requested, "the initial provider request must really exist")
        let firstRequest = try XCTUnwrap(fixture.adapter.lastRequest)
        let originalHumanInputs = firstRequest.messages.filter { $0.role == "user" }.map(\.content)

        let firstDelivery = await domain.noteSettledDependency(
            runID: runID, conversationID: conversationID,
            jobID: jobID, kind: "job", state: .resolved)
        XCTAssertTrue(firstDelivery, "a live parent really receives the receipt")
        // Duplicate terminal callbacks collapse onto the same deterministic id.
        let duplicate = await domain.noteSettledDependency(
            runID: runID, conversationID: conversationID,
            jobID: jobID, kind: "job", state: .resolved)
        XCTAssertTrue(duplicate, "an already-accepted receipt is idempotent")

        gate.release()
        let terminal = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(terminal, "completed")
        XCTAssertEqual(fixture.adapter.requestCount, first + 2,
                       "the notice keeps the SAME live run going for one step")
        let sent = try XCTUnwrap(fixture.adapter.lastRequest)
        let notices = sent.messages.filter {
            $0.role == "system" && $0.content.contains(jobID.uuidString)
        }
        XCTAssertEqual(notices.count, 1,
                       "exactly ONE lifecycle receipt reaches the model")
        XCTAssertTrue(notices[0].content.contains("completed"))
        XCTAssertLessThanOrEqual(notices[0].content.utf8.count, 2_000)
        XCTAssertEqual(sent.messages.filter { $0.role == "user" }.map(\.content), originalHumanInputs,
                       "the receipt never fabricates a human turn")
        let durable = try await fixture.conversationStore
            .messages(conversationID: conversationID)
        let systemRows = durable.filter {
            $0.content == notices[0].content && $0.role == "system"
        }
        XCTAssertEqual(systemRows.count, 1,
                       "the consumed receipt is ONE durable system row")
        XCTAssertEqual(systemRows[0].runID, runID)
    }

    func testSettledDependencyIsNotDeliveredToAParkedOrForeignRun() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let parked = try await makeParkedRun(conversationID: conversationID,
                                             jobID: UUID())
        let foreground = RunForegroundAdmissionStub()
        let domain = fixture.makeCustomDomain(components(foreground: foreground))
        let delivered = await domain.noteSettledDependency(
            runID: parked.runID, conversationID: conversationID,
            jobID: parked.jobID, kind: "job", state: .resolved)
        XCTAssertFalse(delivered,
                       "a parked run has no live service to inform; the parked continuation decides")
        let messages = try await fixture.conversationStore
            .messages(conversationID: conversationID)
        XCTAssertTrue(messages.filter { $0.runID == parked.runID }.isEmpty)
        let parkedState = try await fixture.runState(parked.runID)
        XCTAssertEqual(parkedState, "checkpointed")
        // A foreign conversation id can never attach lifecycle context.
        let foreign = await domain.noteSettledDependency(
            runID: parked.runID, conversationID: UUID(),
            jobID: parked.jobID, kind: "job", state: .resolved)
        XCTAssertFalse(foreign)
    }
}
