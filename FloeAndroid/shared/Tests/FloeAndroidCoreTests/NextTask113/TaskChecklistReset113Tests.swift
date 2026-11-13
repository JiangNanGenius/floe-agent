// SPDX-License-Identifier: MPL-2.0
//
// N10 task continuity — checklist reset / current-round scoping over the REAL
// SQLite run + checklist stores. Authored in the source-only window; NOT
// executed here (the coordinator runs the compiled batch).
import XCTest
import Foundation
import FloeCore
import FloeModels
@testable import FloePersistence
import FloeTools
import FloeAgentRuntime
@testable import FloeAndroidCore

final class TaskChecklistReset113Tests: XCTestCase {
    private var database: DatabaseManager!
    private var conversationID: UUID!
    private var runA: UUID!
    private var runB: UUID!
    private var store: TaskChecklistStore!

    override func setUp() async throws {
        database = try DatabaseManager.inMemory()
        try await database.migrate()
        conversationID = UUID()
        runA = UUID()
        runB = UUID()
        let conversation = conversationID.uuidString
        let firstRunID = runA.uuidString
        let secondRunID = runB.uuidString
        let now = PersistenceCodec.encode(Date(timeIntervalSince1970: 1_760_000_000))
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES (?, ?, ?, ?)
                """, arguments: [conversation, "reset task", now, now])
            try db.execute(sql: """
                INSERT INTO runs (id, conversation_id, state, goal, started_at, conversation_mode)
                VALUES (?, ?, 'streamingModel', 'work', ?, 'chat')
                """, arguments: [firstRunID, conversation,
                                 PersistenceCodec.encode(Date(timeIntervalSince1970: 1_760_000_100))])
            try db.execute(sql: """
                INSERT INTO runs (id, conversation_id, state, goal, started_at, conversation_mode)
                VALUES (?, ?, 'preparing', 'work', ?, 'chat')
                """, arguments: [secondRunID, conversation,
                                 PersistenceCodec.encode(Date(timeIntervalSince1970: 1_760_000_200))])
        }
        store = TaskChecklistStore(database: database)
    }

    private func update(_ title: String, expected: Int? = nil,
                        steps: [TaskChecklist.Step], runID: UUID) async throws -> TaskChecklist {
        try await store.update(
            TaskChecklistUpdate(expectedRevision: expected, title: title, steps: steps),
            runID: runID, operationID: "op-\(UUID().uuidString)")
    }

    private func mainContext(runID: UUID, callID: String,
                             temporary: Bool = false, publicWeb: Bool = false,
                             childBudget: ChildBudgetContext? = nil,
                             origin: ToolCallOrigin? = nil) -> ToolContext {
        ToolContext(
            runID: runID,
            toolCallID: callID,
            publicWebOnly: publicWeb,
            cancellation: CancellationToken(),
            childBudget: childBudget,
            conversationID: conversationID,
            callOrigin: origin ?? ToolCallOrigin(
                kind: .mainRunDelegate, runID: runID, callID: callID,
                toolName: TaskResetPlanTool.name),
            temporaryReadOnly: temporary)
    }

    func testResetIsCASScopedAndKeepsPriorRevisionsAndResetMarker() async throws {
        let first = try await update("Release", steps: [
            .init(id: "one", title: "first", status: .completed, evidence: ["tool:result"]),
            .init(id: "two", title: "second", status: .inProgress),
        ], runID: runB)
        XCTAssertEqual(first.revision, 1)

        let tool = TaskResetPlanTool(store: store)
        let reset = try await tool.execute(
            .init(expectedRevision: 1),
            context: mainContext(runID: runB, callID: "reset-call-1"))
        XCTAssertEqual(reset.summary.contains("\"wasReset\":true"), true)
        let hidden = try await store.latest(conversationID: conversationID)
        XCTAssertNil(hidden, "A reset tombstone is not a current checklist")
        let markerValue = try await store.latest(
            conversationID: conversationID, includeReset: true)
        let marker = try XCTUnwrap(markerValue)
        XCTAssertEqual(marker.revision, 2)
        XCTAssertTrue(marker.wasReset == true)
        XCTAssertTrue(marker.steps.isEmpty)
        XCTAssertFalse(marker.isFinished)
        let hiddenForRun = try await store.latest(runID: runB)
        XCTAssertNil(hiddenForRun)
        // The prior revision is preserved as history, not overwritten.
        let conversation = conversationID.uuidString
        let revisions = try await database.reader { db in
            try Int.fetchAll(db, sql: """
                SELECT revision FROM task_checklist_revisions
                WHERE conversation_id = ? ORDER BY revision
                """, arguments: [conversation])
        }
        XCTAssertEqual(revisions, [1, 2])
        // Reset creates no Goal (progress is never authorization).
        let goals = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation_goals WHERE conversation_id = ?",
                             arguments: [conversation]) ?? -1
        }
        XCTAssertEqual(goals, 0)
    }

    func testResetReplayReturnsOriginalReceiptAndCannotClearLaterWork() async throws {
        _ = try await update("Release", steps: [
            .init(id: "one", title: "first", status: .inProgress),
            .init(id: "two", title: "second", status: .pending),
        ], runID: runB)
        let tool = TaskResetPlanTool(store: store)
        let context = mainContext(runID: runB, callID: "reset-replay")
        _ = try await tool.execute(.init(expectedRevision: 1), context: context)
        // Later work belongs to the same running round after the reset.
        _ = try await update("Fresh", steps: [
            .init(id: "three", title: "new", status: .inProgress),
        ], runID: runB)
        let replay = try await tool.execute(.init(expectedRevision: 1), context: context)
        XCTAssertTrue(replay.summary.contains("\"revision\":2"), "replay returns its original receipt")
        let currentValue = try await store.latest(conversationID: conversationID)
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current.revision, 3)
        XCTAssertEqual(current.steps.map(\.id), ["three"])
    }

    func testResetRefusesStaleRevisionConflictingReplayAndForeignRun() async throws {
        _ = try await update("Release", steps: [
            .init(id: "one", title: "first", status: .inProgress),
        ], runID: runB)
        let tool = TaskResetPlanTool(store: store)
        do {
            _ = try await tool.execute(.init(expectedRevision: 9),
                context: mainContext(runID: runB, callID: "stale"))
            XCTFail("stale revision must refuse")
        } catch let error as FloeError {
            XCTAssertTrue("\(error)".contains("revision"))
        }
        _ = try await tool.execute(.init(expectedRevision: 1),
            context: mainContext(runID: runB, callID: "conflict"))
        do {
            _ = try await tool.execute(.init(expectedRevision: 2),
                context: mainContext(runID: runB, callID: "conflict"))
            XCTFail("same call identity with different args must refuse")
        } catch let error as FloeError {
            XCTAssertTrue("\(error)".contains("different checklist"))
        }
        let foreign = UUID()
        do {
            _ = try await tool.execute(.init(expectedRevision: 2),
                context: mainContext(runID: foreign, callID: "foreign"))
            XCTFail("a foreign run must refuse")
        } catch {
            // unauthorized/validation: no write
        }
    }

    func testResetRequiresCurrentExecutingMainRun() async throws {
        let firstRunID = runA.uuidString
        _ = try await update("Release", steps: [
            .init(id: "one", title: "first", status: .inProgress),
        ], runID: runA)
        try await database.writer { db in
            try db.execute(sql: "UPDATE runs SET ended_at = ? WHERE id = ?",
                arguments: [PersistenceCodec.encode(Date()), firstRunID])
        }
        let tool = TaskResetPlanTool(store: store)
        do {
            _ = try await tool.execute(.init(expectedRevision: 1),
                context: mainContext(runID: runA, callID: "terminal"))
            XCTFail("a terminal run cannot reset")
        } catch {
            // typed refusal, no write
        }
        // The newest still-open run is B; resetting A is superseded.
        try await database.writer { db in
            try db.execute(sql: "UPDATE runs SET ended_at = NULL WHERE id = ?",
                arguments: [firstRunID])
        }
        do {
            _ = try await tool.execute(.init(expectedRevision: 1),
                context: mainContext(runID: runA, callID: "superseded"))
            XCTFail("only the newest open run may reset")
        } catch {
            // typed refusal
        }
    }

    func testResetRefusesTemporaryReadOnlyChildAndForgedOrigins() async throws {
        let secondRunID = runB.uuidString
        _ = try await update("Release", steps: [
            .init(id: "one", title: "first", status: .inProgress),
        ], runID: runB)
        let tool = TaskResetPlanTool(store: store)
        let child = ToolCallOrigin(kind: .delegatedChild, runID: runB,
            callID: "child", toolName: TaskResetPlanTool.name, childID: UUID(),
            rootTaskID: conversationID)
        let budget = ChildBudgetContext(
            maximumIterations: 2, reserve: { true }, finish: {})
        let refused: [ToolContext] = [
            mainContext(runID: runB, callID: "temp", temporary: true),
            mainContext(runID: runB, callID: "public", publicWeb: true),
            mainContext(runID: runB, callID: "child", origin: child),
            mainContext(runID: runB, callID: "budget", childBudget: budget),
            ToolContext(runID: runB, toolCallID: "forged",
                cancellation: CancellationToken(), conversationID: conversationID),
        ]
        for context in refused {
            do {
                _ = try await tool.execute(.init(expectedRevision: 1), context: context)
                XCTFail("context \(context.callOrigin?.kind as Any) must not reset")
            } catch {
                // unauthorized: no write
            }
        }
        let stillCurrentValue = try await store.latest(conversationID: conversationID)
        let stillCurrent = try XCTUnwrap(stillCurrentValue)
        XCTAssertEqual(stillCurrent.revision, 1)
        // A read-only Plan round is not a writing main round even with a
        // perfectly forged main-origin context.
        try await database.writer { db in
            try db.execute(sql: "UPDATE runs SET conversation_mode = 'plan' WHERE id = ?",
                arguments: [secondRunID])
        }
        do {
            _ = try await tool.execute(.init(expectedRevision: 1),
                context: mainContext(runID: runB, callID: "plan-mode"))
            XCTFail("a Plan-mode run cannot reset checklist progress")
        } catch {
            // unauthorized: no write
        }
    }

    func testNewRoundDoesNotInheritAnotherRunsOpenSteps() async throws {
        _ = try await update("Round A", steps: [
            .init(id: "a1", title: "unfinished A", status: .inProgress),
        ], runID: runA)
        // A new round may start its own checklist without carrying A's open
        // steps; A's revision stays as history.
        let roundB = try await update("Round B", steps: [
            .init(id: "b1", title: "new work", status: .inProgress),
        ], runID: runB)
        XCTAssertEqual(roundB.revision, 2)
        XCTAssertEqual(roundB.steps.map(\.id), ["b1"])
        let latestB = try await store.latest(runID: runB)
        XCTAssertEqual(latestB?.runID, runB)
        // The earlier round's unfinished step stays inspectable by its run.
        let historicalA = try await store.latest(
            conversationID: conversationID, runID: runA, includeReset: true)
        XCTAssertEqual(historicalA?.runID, runA)
        XCTAssertEqual(historicalA?.steps.map(\.id), ["a1"])
    }

    func testChecklistProjectionOnlyCoversTheSameActiveRound() async throws {
        let checklist = try await update("Live", steps: [
            .init(id: "one", title: "first", status: .inProgress),
        ], runID: runB)
        let active = ConversationChecklistWire.project(
            checklist: checklist, runID: runB, runState: "streamingModel", runEnded: false)
        XCTAssertEqual(active?.revision, 1)
        XCTAssertEqual(active?.runID, runB)
        XCTAssertNil(ConversationChecklistWire.project(
            checklist: checklist, runID: runA, runState: "preparing", runEnded: false))
        XCTAssertNil(ConversationChecklistWire.project(
            checklist: checklist, runID: runB, runState: "completed", runEnded: true))
        XCTAssertNil(ConversationChecklistWire.project(
            checklist: checklist, runID: runB, runState: "failed", runEnded: true))
        // A reset tombstone is never a current summary.
        let tool = TaskResetPlanTool(store: store)
        let reset = try await tool.execute(.init(expectedRevision: 1),
            context: mainContext(runID: runB, callID: "reset-projection"))
        XCTAssertEqual(reset.summary.contains("\"wasReset\":true"), true)
        let markerValue = try await store.latest(
            conversationID: conversationID, includeReset: true)
        let marker = try XCTUnwrap(markerValue)
        XCTAssertNil(ConversationChecklistWire.project(
            checklist: marker, runID: runB, runState: "streamingModel", runEnded: false))
    }

    func testTerminalDispositionDoesNotTurnLiveRetryIntoFailure() {
        XCTAssertEqual(N113RunTerminal.disposition(state: "streamingModel", isLiveOwner: true), .none)
        XCTAssertEqual(N113RunTerminal.disposition(state: "failed", isLiveOwner: true), .none)
        XCTAssertEqual(N113RunTerminal.disposition(state: "completed", isLiveOwner: true), .none)
        XCTAssertEqual(N113RunTerminal.disposition(state: "cancelled", isLiveOwner: true), .none)
        XCTAssertEqual(N113RunTerminal.disposition(state: "failed", isLiveOwner: false), .failed)
        XCTAssertEqual(N113RunTerminal.disposition(state: "completed", isLiveOwner: false), .completed)
        XCTAssertEqual(N113RunTerminal.disposition(state: "cancelled", isLiveOwner: false), .cancelled)
        XCTAssertEqual(N113RunTerminal.disposition(state: "checkpointed", isLiveOwner: false), .suspended)
        XCTAssertEqual(N113RunTerminal.disposition(state: "interrupted", isLiveOwner: false), .suspended)
        XCTAssertEqual(N113RunTerminal.disposition(state: "waitingApproval", isLiveOwner: true), .waiting)
        XCTAssertEqual(N113RunTerminal.disposition(state: "idle", isLiveOwner: false), .none)
        XCTAssertFalse(N113RunTerminal.isDurableTerminal("streamingModel"))
        XCTAssertEqual(N113PlanPresentation.marker(planID: UUID(uuidString: "2A9BB479-F614-473C-B8E4-008E2DFE8222")!, revision: 7),
                       "2A9BB479-F614-473C-B8E4-008E2DFE8222:7")
    }
}
