// SPDX-License-Identifier: MPL-2.0
//
// G03-R4 — parked-dependency gate: pure decision regressions. AUTHORED, NOT
// EXECUTED here. No store, provider, device or command is used.
import XCTest
import Foundation
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

final class RunDependencyResumeGateTests: XCTestCase {
    private let jobA = UUID()
    private let jobB = UUID()

    // MARK: Reason shapes

    func testReasonShapes() {
        XCTAssertEqual(RunDependencyResumeGate.shape(of: nil), .notAwaiting)
        XCTAssertEqual(RunDependencyResumeGate.shape(of: "runtime.agent_runtime.the_task_was_stopped_by_you"),
                       .notAwaiting)
        XCTAssertEqual(RunDependencyResumeGate.shape(of: "awaiting.finite.job"), .legacy)
        XCTAssertEqual(RunDependencyResumeGate.shape(of: "awaiting.finite.job:"), .legacy)
        XCTAssertEqual(RunDependencyResumeGate.shape(
            of: "awaiting.finite.job:\(jobA.uuidString)"), .named([jobA]))
        XCTAssertEqual(RunDependencyResumeGate.shape(
            of: "awaiting.finite.job:\(jobA.uuidString),\(jobB.uuidString)"),
                       .named([jobA, jobB]))
        XCTAssertEqual(RunDependencyResumeGate.shape(of: "awaiting.finite.job:not-a-uuid"),
                       .malformed)
        XCTAssertEqual(RunDependencyResumeGate.shape(
            of: "awaiting.finite.job:\(jobA.uuidString),broken"), .malformed)
    }

    // MARK: Named edges

    func testAllTerminalEdgesResume() {
        let observations: [RunDependencyObservation] = [
            .terminal(jobID: jobA, kind: "job", state: .resolved),
            .terminal(jobID: jobB, kind: "job", state: .cancelled),
        ]
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .named([jobA, jobB]), observations: observations,
            allowMissing: false), .resume(observations))
    }

    func testAnyPendingEdgeKeepsWaiting() {
        let observations: [RunDependencyObservation] = [
            .terminal(jobID: jobA, kind: "job", state: .resolved),
            .pending(jobID: jobB, kind: "job"),
        ]
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .named([jobA, jobB]), observations: observations,
            allowMissing: false), .waiting([jobB]))
    }

    func testUnnamedPendingEdgeStillKeepsWaiting() {
        let observations: [RunDependencyObservation] = [
            .terminal(jobID: jobA, kind: "job", state: .resolved),
            .pending(jobID: jobB, kind: "job"),
        ]
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .named([jobA]), observations: observations,
            allowMissing: false), .waiting([jobB]))
    }

    func testMissingEdgeIsUnverifiedForALiveCallback() {
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .named([jobA]),
            observations: [.missing(jobID: jobA)], allowMissing: false),
                       .unverified)
    }

    func testMissingEdgeIsHonestOnlyForAnExplicitContinue() {
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .named([jobA]),
            observations: [.missing(jobID: jobA)],
            allowMissing: true, allowUncertain: false), .unverified,
                       "an automatic continuation may not invent an unknown outcome")
        let decision = RunDependencyResumeGate.decide(
            shape: .named([jobA]),
            observations: [.missing(jobID: jobA)],
            allowMissing: true, allowUncertain: true)
        guard case .resume(let edges) = decision else {
            return XCTFail("expected an interrupted resume decision, got \(decision)")
        }
        XCTAssertEqual(edges, [.terminal(jobID: jobA, kind: "job",
                                         state: .interrupted)])
    }

    func testInterruptedDependencyNeverResumesAutomatically() {
        let observations: [RunDependencyObservation] = [
            .terminal(jobID: jobA, kind: "job", state: .interrupted),
        ]
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .named([jobA]), observations: observations,
            allowMissing: false, allowUncertain: false), .unverified,
                       "a previous process's uncertain cleanup must not start a model")
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .named([jobA]), observations: observations,
            allowMissing: true, allowUncertain: true), .resume(observations),
                       "an explicit user Continue may reopen with an unknown outcome")
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .legacy, observations: observations,
            allowMissing: false, allowUncertain: false), .unverified)
    }

    func testFailedAndCancelledOutcomesStillResumeTheLiveParent() {
        for state in [RunDependencyState.failed, .cancelled] {
            let observations: [RunDependencyObservation] = [
                .terminal(jobID: jobA, kind: "job", state: state),
            ]
            XCTAssertEqual(RunDependencyResumeGate.decide(
                shape: .named([jobA]), observations: observations,
                allowMissing: false, allowUncertain: false),
                           .resume(observations))
        }
    }

    func testUnreadableStoreNeverResumes() {
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .named([jobA]), observations: nil, allowMissing: false),
                       .unverified)
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .legacy, observations: nil, allowMissing: true), .unverified)
    }

    func testAbsentEdgeInStoreIsUnverified() {
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .named([jobA]), observations: [], allowMissing: false),
                       .unverified)
    }

    // MARK: Legacy checkpoints

    func testLegacyCheckpointResumesOnlyWithNoPendingEdge() {
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .legacy, observations: [], allowMissing: false),
                       .resume([]))
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .legacy,
            observations: [.pending(jobID: jobA, kind: "job")],
            allowMissing: false), .waiting([jobA]))
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .legacy,
            observations: [.terminal(jobID: jobA, kind: "service",
                                     state: .resolved)],
            allowMissing: false),
                       .resume([.terminal(jobID: jobA, kind: "service",
                                          state: .resolved)]))
    }

    func testMalformedMarkerAndNonParkReasonNeverResume() {
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .malformed, observations: [], allowMissing: true),
                       .unverified)
        XCTAssertEqual(RunDependencyResumeGate.decide(
            shape: .notAwaiting, observations: [], allowMissing: true),
                       .notAwaiting)
    }

    // MARK: Deterministic lifecycle message

    func testResumptionMessageIdentityIsStableAndStateSensitive() {
        let runID = UUID()
        let edges: [RunDependencyObservation] = [
            .terminal(jobID: jobA, kind: "job", state: .resolved),
            .terminal(jobID: jobB, kind: "service", state: .resolved),
        ]
        let first = FacadeRunDomain.dependencyResumptionMessageID(
            runID: runID, edges: edges)
        let reordered = FacadeRunDomain.dependencyResumptionMessageID(
            runID: runID, edges: Array(edges.reversed()))
        XCTAssertEqual(first, reordered,
                       "edge ordering must not change the exactly-once message id")
        let changed = FacadeRunDomain.dependencyResumptionMessageID(
            runID: runID,
            edges: [.terminal(jobID: jobA, kind: "job", state: .failed),
                    .terminal(jobID: jobB, kind: "service", state: .resolved)])
        XCTAssertNotEqual(first, changed,
                          "a different durable outcome is a different lifecycle cause")
    }

    // MARK: Parked Stop CAS

    func testParkedStopCommitsOnlyFromTheExpectedCheckpointedState() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let runStore = SQLiteRunStore(database: database)
        let conversationID = UUID()
        let runID = UUID()
        try await SQLiteConversationStore(database: database)
            .saveConversation(ConversationRecord(
                id: conversationID, title: "fixture",
                createdAt: Date(), updatedAt: Date()))
        try await runStore.saveRun(RunRecord(
            id: runID, conversationID: conversationID, state: "checkpointed",
            goal: "waiting", startedAt: Date(), conversationMode: "chat"))
        let committer = G02ParkedRunStopCommitter(database: database)
        let committed = await committer.commit(
            runID: runID, conversationID: conversationID,
            expectedState: "checkpointed")
        XCTAssertTrue(committed)
        let stoppedState = try await runStore.run(id: runID)?.state
        XCTAssertEqual(stoppedState, "checkpointed",
                       "a stopped run keeps Android's terminal checkpointed vocabulary")
        let events = try await runStore.events(runID: runID)
        XCTAssertTrue(events.contains {
            $0.kind == .status
                && $0.payloadJSON.contains("\"reason\":\"runtime.agent_runtime.the_task_was_stopped_by_you\"")
        })

        // A resume that already committed `preparing` is never overwritten by
        // a Stop.
        let resumedID = UUID()
        try await runStore.saveRun(RunRecord(
            id: resumedID, conversationID: conversationID, state: "preparing",
            goal: "continuing", startedAt: Date(), conversationMode: "chat"))
        let refused = await committer.commit(
            runID: resumedID, conversationID: conversationID,
            expectedState: "checkpointed")
        XCTAssertFalse(refused)
        let resumedState = try await runStore.run(id: resumedID)?.state
        XCTAssertEqual(resumedState, "preparing")
    }

    func testResumeNoteNamesOnlyIdentitiesAndStates() {
        let note = FacadeRunDomain.dependencyResumeNote(edges: [
            .terminal(jobID: jobA, kind: "job", state: .resolved),
            .terminal(jobID: jobB, kind: "service", state: .cancelled),
            .missing(jobID: UUID()),
        ])
        XCTAssertTrue(note.contains(jobA.uuidString))
        XCTAssertTrue(note.contains("completed"))
        XCTAssertTrue(note.contains("was cancelled"))
        XCTAssertTrue(note.contains("outcome is unknown"))
        XCTAssertTrue(note.contains("jobs.status"))
        XCTAssertLessThanOrEqual(note.utf8.count, 2_000)
        XCTAssertFalse(note.contains("exec.shell"))
        XCTAssertFalse(note.contains("/"))
        XCTAssertFalse(note.contains("workspace"))
    }
}
