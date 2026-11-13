// SPDX-License-Identifier: MPL-2.0
//
// N10 child-scope repair (job-598f14db64d64d18) — checklist isolation.
//
// PROVEN NATIVE FAILURE: a delegated execute child called
// checklist.updatePlan and appended its own arith/build/verify/publish steps
// to the PARENT's checklist revision. The parent's next update was then
// rejected because those child steps were absent, forcing extra read/repair
// turns. The child did not need checklist writes at all: its own bounded
// iterations are already tracked by the child budget.
//
// These fixtures exercise the REAL SQLite checklist store and the REAL
// TaskUpdatePlanTool/TaskResetPlanTool boundaries. They are authored in the
// source-only window and are NOT executed here; the coordinator runs the
// compiled batch.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeAgentRuntime
@testable import FloeAndroidCore

final class TaskChecklistChildIsolation113Tests: XCTestCase {
    private var database: DatabaseManager!
    private var conversationID: UUID!
    private var runID: UUID!
    private var store: TaskChecklistStore!

    override func setUp() async throws {
        database = try DatabaseManager.inMemory()
        try await database.migrate()
        conversationID = UUID()
        runID = UUID()
        let conversation = conversationID.uuidString
        let run = runID.uuidString
        let now = PersistenceCodec.encode(Date(timeIntervalSince1970: 1_760_000_000))
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES (?, ?, ?, ?)
                """, arguments: [conversation, "child isolation", now, now])
            try db.execute(sql: """
                INSERT INTO runs (id, conversation_id, state, goal, started_at, conversation_mode)
                VALUES (?, ?, 'streamingModel', 'work', ?, 'chat')
                """, arguments: [run, conversation,
                                 PersistenceCodec.encode(Date(timeIntervalSince1970: 1_760_000_100))])
        }
        store = TaskChecklistStore(database: database)
        // Parent revision 1: the title/steps/revision child writes must never
        // replace, even when they carry the same run identity.
        _ = try await store.update(
            TaskChecklistUpdate(title: "Parent plan", steps: [
                .init(id: "parent-setup", title: "parent setup", status: .completed,
                      evidence: ["parent:tool-result"]),
                .init(id: "parent-child", title: "parent delegate", status: .inProgress),
                .init(id: "parent-publish", title: "parent publish", status: .pending),
            ]),
            runID: runID, operationID: "parent-seed")
    }

    private func handoff(childID: UUID = UUID()) -> ChildExecutionHandoff {
        ChildExecutionHandoff(
            identity: ChildExecutionIdentity(
                childID: childID, parentRunID: runID,
                rootTaskID: conversationID, delegateCallID: "delegate-call-1"),
            dispatcher: ChildToolDispatcher(
                descriptorProvider: { _ in nil },
                allDescriptors: { [] },
                dispatch: { call, _ in
                    ToolResult(callID: call.id, status: .denied,
                               outputSummary: "child dispatcher fixture", outputDigest: "")
                }),
            peers: PeerCollaborationHandle(
                register: { _ in },
                unregister: {},
                drain: { [] },
                peers: { _ in [] },
                send: { _, _, _ in SubagentPeerSendReceipt(accepted: false) }))
    }

    /// A delegated-child context with every trusted marker the real runner
    /// supplies. `reserve` only models whether the child still has an
    /// iteration slot; it must never influence the parent checklist.
    private func childContext(
        label: String,
        budgetRemaining: Bool = true,
        cancelled: Bool = false,
        forgedMainOrigin: Bool = false
    ) -> ToolContext {
        let childID = UUID()
        let callID = "child-\(label)"
        let token = CancellationToken()
        if cancelled { token.cancel() }
        let budget = ChildBudgetContext(
            maximumIterations: 8,
            reserve: { budgetRemaining },
            finish: {})
        let origin = ToolCallOrigin(
            kind: forgedMainOrigin ? .mainRunDelegate : .delegatedChild,
            runID: runID,
            callID: callID,
            toolName: TaskUpdatePlanTool.name,
            childID: childID,
            rootTaskID: conversationID)
        return ToolContext(
            runID: runID,
            toolCallID: callID,
            cancellation: token,
            childBudget: budget,
            conversationID: conversationID,
            childExecution: handoff(childID: childID),
            callOrigin: origin)
    }

    private func childPlan() -> TaskChecklistUpdate {
        TaskChecklistUpdate(title: "Child plan", steps: [
            .init(id: "arith", title: "child arithmetic", status: .completed,
                  evidence: ["child:measured"]),
            .init(id: "build", title: "child build", status: .inProgress),
            .init(id: "publish", title: "child publish", status: .pending),
        ])
    }

    private func assertParentUnchanged(_ label: String) async throws {
        let latest = try await store.latest(conversationID: conversationID)
        let checklist = try XCTUnwrap(latest, "\(label): parent checklist disappeared")
        XCTAssertEqual(checklist.revision, 1, "\(label): child write changed the revision")
        XCTAssertEqual(checklist.runID, runID, "\(label): child write changed the owning run")
        XCTAssertEqual(checklist.title, "Parent plan", "\(label): child write changed the title")
        XCTAssertEqual(checklist.steps.map(\.id),
                       ["parent-setup", "parent-child", "parent-publish"],
                       "\(label): child write replaced the parent steps")
        XCTAssertEqual(checklist.completedCount, 1, "\(label): child write changed completion state")
        XCTAssertNil(checklist.steps.first { $0.id == "arith" },
                     "\(label): a child-only step leaked into the parent checklist")
    }

    /// The native failure's second half: after the child attempts, the REAL
    /// main-run update must succeed on the untouched parent revision. A child
    /// step that leaked in would make this fail with the exact
    /// "still unfinished ... arith/build/verify/publish" rejection.
    private func assertMainRunCanStillUpdate(_ label: String) async throws {
        let callID = "main-after-\(label)"
        let main = ToolContext(
            runID: runID,
            toolCallID: callID,
            cancellation: CancellationToken(),
            conversationID: conversationID,
            callOrigin: ToolCallOrigin(
                kind: .mainRunDelegate, runID: runID,
                callID: callID, toolName: TaskUpdatePlanTool.name))
        let updated = try await TaskUpdatePlanTool(store: store).execute(
            TaskChecklistUpdate(title: "Parent plan", steps: [
                .init(id: "parent-setup", title: "parent setup", status: .completed,
                      evidence: ["parent:tool-result"]),
                .init(id: "parent-child", title: "parent delegate", status: .completed,
                      evidence: ["delegate:partial-receipt"]),
                .init(id: "parent-publish", title: "parent publish", status: .inProgress),
            ]),
            context: main)
        XCTAssertTrue(updated.summary.contains("\"revision\":2"),
                      "\(label): the parent update must not inherit child steps")
        let currentValue = try await store.latest(conversationID: conversationID)
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current.revision, 2)
        XCTAssertEqual(current.steps.map(\.id),
                       ["parent-setup", "parent-child", "parent-publish"])
    }

    func testChecklistWriteToolsAreStructurallyMainRunOnly() {
        // Discovery excludes main-only descriptors from every child, and the
        // canonical dispatcher refuses them even if a stale schema is called.
        XCTAssertEqual(TaskUpdatePlanTool.executionBoundary, .mainRunOnly)
        XCTAssertEqual(TaskResetPlanTool.executionBoundary, .mainRunOnly)
    }

    func testChildUpdateIsRefusedOnSuccessFailureCancelAndIterationLimitPaths() async throws {
        let tool = TaskUpdatePlanTool(store: store)
        let scenarios: [(String, ToolContext)] = [
            ("success-final-answer", childContext(label: "success")),
            ("failed-tool", childContext(label: "failed")),
            ("cancelled", childContext(label: "cancelled", cancelled: true)),
            ("iteration-limited", childContext(label: "limit", budgetRemaining: false)),
            ("forged-main-origin", childContext(label: "forged", forgedMainOrigin: true)),
        ]
        for (label, context) in scenarios {
            do {
                _ = try await tool.execute(childPlan(), context: context)
                XCTFail("\(label): a delegated child must not write the parent checklist")
            } catch {
                // Unauthorized/cancelled: no write.
            }
            try await assertParentUnchanged(label)
        }
        try await assertMainRunCanStillUpdate("child-update")
    }

    func testChildResetIsRefusedOnTheSamePaths() async throws {
        let tool = TaskResetPlanTool(store: store)
        let scenarios: [(String, ToolContext)] = [
            ("success-final-answer", childContext(label: "reset-success")),
            ("cancelled", childContext(label: "reset-cancelled", cancelled: true)),
            ("iteration-limited", childContext(label: "reset-limit", budgetRemaining: false)),
            ("forged-main-origin", childContext(label: "reset-forged", forgedMainOrigin: true)),
        ]
        for (label, context) in scenarios {
            // The origin is bound to updatePlan, not resetPlan; the child
            // handoff alone must also refuse it.
            do {
                _ = try await tool.execute(.init(expectedRevision: 1), context: context)
                XCTFail("\(label): a delegated child must not reset the parent checklist")
            } catch {
                // Unauthorized: no write.
            }
            try await assertParentUnchanged(label)
        }
    }

    func testChildReadIsSideEffectFreeAndMainRunStillWritesNormally() async throws {
        let read = TaskReadPlanTool(store: store)
        let before = try await store.latest(conversationID: conversationID)
        let summary = try await read.execute(.init(), context: childContext(label: "read"))
        XCTAssertTrue(summary.summary.contains("Parent plan"),
                      "the child read the real parent progress without mutating it")
        let afterRead = try await store.latest(conversationID: conversationID)
        XCTAssertEqual(afterRead, before, "readPlan must not create a revision")

        // The real main-run call still updates the SAME checklist. This is
        // the control that proves the boundary did not disable parent progress.
        let mainCallID = "main-update-1"
        let main = ToolContext(
            runID: runID,
            toolCallID: mainCallID,
            cancellation: CancellationToken(),
            conversationID: conversationID,
            callOrigin: ToolCallOrigin(
                kind: .mainRunDelegate, runID: runID,
                callID: mainCallID, toolName: TaskUpdatePlanTool.name))
        let updated = try await TaskUpdatePlanTool(store: store).execute(
            TaskChecklistUpdate(title: "Parent plan", steps: [
                .init(id: "parent-setup", title: "parent setup", status: .completed,
                      evidence: ["parent:tool-result"]),
                .init(id: "parent-child", title: "parent delegate", status: .completed,
                      evidence: ["delegate:partial-receipt"]),
                .init(id: "parent-publish", title: "parent publish", status: .inProgress),
            ]),
            context: main)
        XCTAssertTrue(updated.summary.contains("\"revision\":2"))
        let latestValue = try await store.latest(conversationID: conversationID)
        let latest = try XCTUnwrap(latestValue)
        XCTAssertEqual(latest.revision, 2)
        XCTAssertEqual(latest.steps.map(\.id),
                       ["parent-setup", "parent-child", "parent-publish"])
        XCTAssertEqual(latest.completedCount, 2)
    }
}
