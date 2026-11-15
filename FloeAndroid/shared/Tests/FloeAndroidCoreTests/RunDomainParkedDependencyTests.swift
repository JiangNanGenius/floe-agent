// SPDX-License-Identifier: MPL-2.0
//
// G03-R4 — the REAL run-domain continuation/Stop path over the ORIGINAL
// stores/checkpoint/runtime. AUTHORED, NOT EXECUTED here. The model stream is
// the fixture's scripted adapter; every other component is production code.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
@testable import FloeAndroidCore

final class RunDomainParkedDependencyTests: XCTestCase {
    private var fixture: RunDomainFixture!

    override func setUp() async throws {
        fixture = try await RunDomainFixture.make()
    }

    override func tearDown() async throws {
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    // MARK: Fixtures

    private struct Parked {
        var runID: UUID
        var conversationID: UUID
        var dependencies: SQLiteRunDependencyStore
        var jobIDs: [UUID]
    }

    private func components(cancelledJobs: [UUID] = []) -> RunDomainComponents {
        let base = fixture.components()
        let database = fixture.database
        var bound = base
        bound.runDependencyEdges = G02RunDependencyEdgeReader(database: database)
        bound.commitParkedRunStop = { runID, conversationID, expected in
            await G02ParkedRunStopCommitter(database: database).commit(
                runID: runID, conversationID: conversationID,
                expectedState: expected)
        }
        let requested = cancelledJobs
        bound.cancelParkedRunJobs = { _, _, _ in requested }
        return bound
    }

    private func makeParkedRun(
        conversationID: UUID,
        named: [UUID],
        edges: [(jobID: UUID, state: RunDependencyState)],
        state: String = "checkpointed"
    ) async throws -> Parked {
        let runID = UUID()
        let goal = "finish the required background work"
        try await fixture.runStore.saveRun(RunRecord(
            id: runID, conversationID: conversationID, state: state,
            goal: goal, startedAt: Date().addingTimeInterval(-120),
            endedAt: Date(), providerID: fixture.providerID,
            modelID: fixture.modelID, conversationMode: "chat"))
        let checkpoint = AgentCheckpoint(
            runID: runID, conversationID: conversationID,
            state: .preparing(.init(goal: goal)),
            messages: [ConversationMessage(role: "user", content: goal)],
            schemaVersion: DatabaseManager.currentSchemaVersion)
        try await fixture.checkpoints.save(checkpoint)
        let reason = named.isEmpty
            ? "awaiting.finite.job"
            : "awaiting.finite.job:" + named.map(\.uuidString).joined(separator: ",")
        let payload = try JSONSerialization.data(withJSONObject: [
            "state": "checkpointed", "reason": reason,
        ], options: [.sortedKeys])
        _ = try await fixture.runStore.appendEvent(
            runID: runID, kind: .status,
            payloadJSON: String(decoding: payload, as: UTF8.self))
        let dependencies = SQLiteRunDependencyStore(database: fixture.database)
        for edge in edges {
            try await dependencies.register(RunDependencyRecord(
                jobID: edge.jobID, runID: runID,
                conversationID: conversationID, kind: "job"))
            if edge.state != .pending {
                _ = try await dependencies.resolve(
                    jobID: edge.jobID, state: edge.state, note: nil)
            }
        }
        return Parked(runID: runID, conversationID: conversationID,
                      dependencies: dependencies,
                      jobIDs: named)
    }

    private func enqueueAnswer(_ text: String) -> Int {
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: text)),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: index)
        return index
    }

    // MARK: Automatic continuation

    func testSettledDependencyResumesTheExactOriginalRunOnce() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let jobID = UUID()
        let parked = try await makeParkedRun(
            conversationID: conversationID, named: [jobID],
            edges: [(jobID, .resolved)])
        let domain = fixture.makeCustomDomain(components())
        let requestsBefore = fixture.adapter.requestCount
        _ = enqueueAnswer("The background work completed; here is the updated answer.")

        let result = await domain.resumeAwaitingDependency(
            runID: parked.runID, conversationID: conversationID)
        XCTAssertEqual(result, .resumed)
        let terminal = await waitDurableTerminal(fixture: fixture,
                                                 runID: parked.runID)
        XCTAssertEqual(terminal, "completed")
        XCTAssertGreaterThan(fixture.adapter.requestCount, requestsBefore,
                             "the resumed run must dispatch a real provider turn")
        let messages = try await fixture.conversationStore.messages(
            conversationID: conversationID)
        let lifecycle = messages.filter {
            $0.runID == parked.runID && $0.role == "system"
        }
        XCTAssertEqual(lifecycle.count, 1,
                       "exactly ONE trusted lifecycle message is persisted")
        XCTAssertTrue(lifecycle[0].content.contains(jobID.uuidString))
        XCTAssertLessThanOrEqual(lifecycle[0].content.utf8.count, 2_000)
        let sent = try XCTUnwrap(fixture.adapter.lastRequest)
        XCTAssertEqual(sent.messages.filter { $0.content.contains(lifecycle[0].content) }.map(\.role),
                       ["system"],
                       "native completion must not impersonate user input")
        XCTAssertEqual(sent.messages.filter { $0.role == "user" }.count, 1)

        // A late/duplicate callback cannot resume a completed run or add a
        // second lifecycle message.
        let duplicate = await domain.resumeAwaitingDependency(
            runID: parked.runID, conversationID: conversationID)
        XCTAssertEqual(duplicate, .notAwaiting)
        let after = try await fixture.conversationStore.messages(
            conversationID: conversationID)
        XCTAssertEqual(after.filter {
            $0.runID == parked.runID && $0.role == "system"
        }.count, 1)
    }

    func testPendingDependencyKeepsTheRunParked() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let jobID = UUID()
        let parked = try await makeParkedRun(
            conversationID: conversationID, named: [jobID],
            edges: [(jobID, .pending)])
        let domain = fixture.makeCustomDomain(components())
        let requestsBefore = fixture.adapter.requestCount

        let result = await domain.resumeAwaitingDependency(
            runID: parked.runID, conversationID: conversationID)
        XCTAssertEqual(result, .waiting([jobID]))
        XCTAssertEqual(fixture.adapter.requestCount, requestsBefore,
                       "a pending edge must not spend a provider turn")
        let stillParked = try await fixture.runState(parked.runID)
        XCTAssertEqual(stillParked, "checkpointed")
    }

    func testMultipleDependenciesResumeOnlyAfterTheLastSettles() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let first = UUID()
        let second = UUID()
        let parked = try await makeParkedRun(
            conversationID: conversationID, named: [first, second],
            edges: [(first, .resolved), (second, .pending)])
        let domain = fixture.makeCustomDomain(components())

        let waiting = await domain.resumeAwaitingDependency(
            runID: parked.runID, conversationID: conversationID)
        XCTAssertEqual(waiting, .waiting([second]))
        _ = try await parked.dependencies.resolve(
            jobID: second, state: .failed, note: "fixture failure")
        _ = enqueueAnswer("One dependency failed; the other completed.")
        let resumed = await domain.resumeAwaitingDependency(
            runID: parked.runID, conversationID: conversationID)
        XCTAssertEqual(resumed, .resumed)
        let terminal = await waitDurableTerminal(fixture: fixture,
                                                 runID: parked.runID)
        XCTAssertEqual(terminal, "completed")
        let messages = try await fixture.conversationStore.messages(
            conversationID: conversationID)
        let lifecycle = try XCTUnwrap(messages.first {
            $0.runID == parked.runID && $0.role == "system"
        })
        XCTAssertTrue(lifecycle.content.contains("failed"))
        XCTAssertTrue(lifecycle.content.contains("completed"))
    }

    func testLegacyParkReasonWithoutIdentifiersResumesWhenNoEdgeIsPending() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let parked = try await makeParkedRun(
            conversationID: conversationID, named: [], edges: [])
        let domain = fixture.makeCustomDomain(components())
        _ = enqueueAnswer("Legacy checkpoint continued.")

        let result = await domain.resumeAwaitingDependency(
            runID: parked.runID, conversationID: conversationID)
        XCTAssertEqual(result, .resumed)
        let terminal = await waitDurableTerminal(fixture: fixture,
                                                 runID: parked.runID)
        XCTAssertEqual(terminal, "completed")
    }

    func testInterruptedOrMissingDependencyNeverAutoResumesAfterRecovery() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let interruptedJob = UUID()
        // A previous process's cleanup left the outcome unknown. Cold recovery
        // resolved the edge honestly as interrupted — the automatic
        // continuation must NOT start a model turn on that basis.
        let interrupted = try await makeParkedRun(
            conversationID: conversationID, named: [interruptedJob],
            edges: [(interruptedJob, .interrupted)])
        let domain = fixture.makeCustomDomain(components())
        let requestsBefore = fixture.adapter.requestCount
        let auto = await domain.resumeAwaitingDependency(
            runID: interrupted.runID, conversationID: conversationID)
        XCTAssertEqual(auto, .unverified)
        XCTAssertEqual(fixture.adapter.requestCount, requestsBefore,
                       "an uncertain old outcome must not auto-start a model")
        let stillParked = try await fixture.runState(interrupted.runID)
        XCTAssertEqual(stillParked, "checkpointed")

        // A missing durable edge (a pre-edge checkpoint) is equally
        // uncertain and never auto-resumes.
        let missingJob = UUID()
        let missing = try await makeParkedRun(
            conversationID: conversationID, named: [missingJob], edges: [])
        let missingAuto = await domain.resumeAwaitingDependency(
            runID: missing.runID, conversationID: conversationID)
        XCTAssertEqual(missingAuto, .unverified)
        XCTAssertEqual(fixture.adapter.requestCount, requestsBefore)

        // The user may still decide to continue explicitly; that is the only
        // path that opens an interrupted outcome.
        _ = enqueueAnswer("The user chose to continue after the uncertain stop.")
        let receipt = try XCTUnwrap(fixture.effects.register(
            correlationID: "corr-continue-interrupted"))
        let reply = await domain.retry(
            envelope: fixture.executionEnvelope(
                command: "run.retry", conversationID: conversationID,
                runID: interrupted.runID,
                payload: ["expectedState": "checkpointed"],
                correlation: "corr-continue-interrupted",
                revision: [
                    "resourceID": RunWireRevision.runResourceID(interrupted.runID),
                    "version": "checkpointed",
                ]),
            receipt: receipt)
        guard case .mutationAccepted(let detail) = reply.outcome else {
            return XCTFail("explicit Continue must reopen a settled edge, got \(reply.outcome)")
        }
        XCTAssertEqual(detail["resumed"], "true")
        _ = await waitDurableTerminal(fixture: fixture, runID: interrupted.runID)
    }

    func testCompletedOrForeignRunIsNeverResumed() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let jobID = UUID()
        let completed = try await makeParkedRun(
            conversationID: conversationID, named: [jobID],
            edges: [(jobID, .resolved)], state: "completed")
        let domain = fixture.makeCustomDomain(components())
        let requestsBefore = fixture.adapter.requestCount
        let completedResult = await domain.resumeAwaitingDependency(
            runID: completed.runID, conversationID: conversationID)
        XCTAssertEqual(completedResult, .notAwaiting)
        let foreignResult = await domain.resumeAwaitingDependency(
            runID: completed.runID, conversationID: UUID())
        XCTAssertEqual(foreignResult, .notAwaiting)
        XCTAssertEqual(fixture.adapter.requestCount, requestsBefore)
    }

    // MARK: Explicit Stop

    func testStopFencesTheRunAndItsPendingEdges() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let jobID = UUID()
        let parked = try await makeParkedRun(
            conversationID: conversationID, named: [jobID],
            edges: [(jobID, .pending)])
        let domain = fixture.makeCustomDomain(components(cancelledJobs: [jobID]))
        let requestsBefore = fixture.adapter.requestCount

        let stopped = await domain.stopAwaitingDependency(
            runID: parked.runID, conversationID: conversationID)
        XCTAssertEqual(stopped, .stopped(cancelledJobIDs: [jobID]))
        let stoppedState = try await fixture.runState(parked.runID)
        XCTAssertEqual(stoppedState, "checkpointed",
                       "a stopped run keeps Android's terminal checkpointed vocabulary")
        let edge = try await parked.dependencies.record(jobID: jobID)
        XCTAssertEqual(edge?.state, .cancelled)
        let checkpoint = try await fixture.checkpoints.load(runID: parked.runID)
        XCTAssertEqual(checkpoint?.state.name, "checkpointed")
        if case .checkpointed(let reference) = checkpoint?.state {
            XCTAssertEqual(reference.reason, FacadeRunDomain.parkedUserStopReason)
        } else {
            XCTFail("the stopped checkpoint must remain a checkpoint")
        }
        // A late completion cannot revive the stopped run.
        let late = await domain.resumeAwaitingDependency(
            runID: parked.runID, conversationID: conversationID)
        XCTAssertEqual(late, .notAwaiting)
        XCTAssertEqual(fixture.adapter.requestCount, requestsBefore,
                       "a stopped run never starts a provider turn")
        // A second Stop is truthful (already terminal), never a rewrite.
        let second = await domain.stopAwaitingDependency(
            runID: parked.runID, conversationID: conversationID)
        XCTAssertEqual(second, .alreadyStarted(state: "checkpointed"))
    }

    func testStopDoesNotTouchAnotherRunInTheSameTask() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let jobA = UUID()
        let jobB = UUID()
        let first = try await makeParkedRun(
            conversationID: conversationID, named: [jobA],
            edges: [(jobA, .pending)])
        let second = try await makeParkedRun(
            conversationID: conversationID, named: [jobB],
            edges: [(jobB, .pending)])
        let domain = fixture.makeCustomDomain(components(cancelledJobs: [jobA]))
        _ = await domain.stopAwaitingDependency(
            runID: first.runID, conversationID: conversationID)
        let firstState = try await fixture.runState(first.runID)
        let secondState = try await fixture.runState(second.runID)
        XCTAssertEqual(firstState, "checkpointed")
        XCTAssertEqual(secondState, "checkpointed")
        let firstReason = await domain.durableCheckpointReason(runID: first.runID)
        let secondReason = await domain.durableCheckpointReason(runID: second.runID)
        XCTAssertEqual(firstReason, FacadeRunDomain.parkedUserStopReason,
                       "the stopped run carries the canonical stop cause")
        XCTAssertTrue(secondReason?.hasPrefix("awaiting.finite.job") == true,
                      "the other run is still parked on its own dependency")
        let secondEdge = try await second.dependencies.record(jobID: jobB)
        XCTAssertEqual(secondEdge?.state, .pending,
                       "another run's dependency edge is untouched")
    }

    // MARK: Explicit Continue after settled edges

    func testContinueIsAllowedOnlyAfterEveryRequiredEdgeSettles() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let jobID = UUID()
        let parked = try await makeParkedRun(
            conversationID: conversationID, named: [jobID],
            edges: [(jobID, .pending)])
        let domain = fixture.makeCustomDomain(components())
        let receipt = try XCTUnwrap(fixture.effects.register(
            correlationID: "corr-continue"))
        let pendingReply = await domain.retry(
            envelope: fixture.executionEnvelope(
                command: "run.retry", conversationID: conversationID,
                runID: parked.runID,
                payload: ["expectedState": "checkpointed"],
                correlation: "corr-continue",
                revision: [
                    "resourceID": RunWireRevision.runResourceID(parked.runID),
                    "version": "checkpointed",
                ]),
            receipt: receipt)
        guard case .rejected(let error) = pendingReply.outcome else {
            return XCTFail("Continue while a required edge is pending must refuse")
        }
        XCTAssertEqual(error.reason.rawValue, "runAwaitingDependency")

        _ = try await parked.dependencies.resolve(
            jobID: jobID, state: .resolved, note: "fixture completion")
        _ = enqueueAnswer("Continued after the dependency settled.")
        let secondReceipt = try XCTUnwrap(fixture.effects.register(
            correlationID: "corr-continue2"))
        let reply = await domain.retry(
            envelope: fixture.executionEnvelope(
                command: "run.retry", conversationID: conversationID,
                runID: parked.runID,
                payload: ["expectedState": "checkpointed"],
                correlation: "corr-continue2",
                revision: [
                    "resourceID": RunWireRevision.runResourceID(parked.runID),
                    "version": "checkpointed",
                ]),
            receipt: secondReceipt)
        guard case .mutationAccepted(let detail) = reply.outcome else {
            return XCTFail("Continue must be accepted after every edge settled, got \(reply.outcome)")
        }
        XCTAssertEqual(detail["resumed"], "true")
        _ = await waitDurableTerminal(fixture: fixture, runID: parked.runID)
    }
}
