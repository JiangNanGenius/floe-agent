import Foundation
import GRDB
import Testing
import FloePersistence
import FloeTools
import FloeCore
@testable import FloeAgentRuntime

@Suite("Durable task checklists")
struct TaskChecklistTests {
    private func fixture() async throws -> (DatabaseManager, UUID, UUID) {
        let db = try DatabaseManager.inMemory()
        try await db.migrate()
        let task = UUID(), run = UUID()
        try await SQLiteConversationStore(database: db).saveConversation(.init(id: task, title: "Checklist", createdAt: Date(), updatedAt: Date()))
        try await SQLiteRunStore(database: db).saveRun(.init(id: run, conversationID: task, state: "running", goal: "Test", startedAt: Date()))
        return (db, task, run)
    }

    @Test func sharedProgressRejectsLateAndUnrelatedSnapshots() async throws {
        let (db, task, run) = try await fixture()
        let store = TaskChecklistStore(database: db)
        let first = try await store.update(.init(expectedRevision: 0, title: "Work", steps: [
            .init(id: "a", title: "Inspect", status: .completed, evidence: ["report.txt"]),
            .init(id: "b", title: "Build", status: .inProgress),
            .init(id: "c", title: "Removed", status: .cancelled)
        ]), runID: run, operationID: "first")
        #expect(first.progressSummary == "已完成 1/3 项 · 已取消 1 项")
        #expect(first.currentStep?.id == "b")
        #expect(!first.isFinished)
        #expect(first.canReplace(nil, conversationID: task))
        #expect(!first.canReplace(nil, conversationID: UUID()))
        #expect(!first.canReplace(first, conversationID: task))
        let second = try await store.update(.init(expectedRevision: 1, title: "Work", steps: [
            .init(id: "a", title: "Inspect", status: .completed, evidence: ["report.txt"]),
            .init(id: "b", title: "Build", status: .blocked),
            .init(id: "c", title: "Removed", status: .cancelled)
        ]), runID: run, operationID: "second")
        #expect(second.currentStep == nil)
        #expect(second.canReplace(first, conversationID: task))
        #expect(!first.canReplace(second, conversationID: task))
    }

    @Test func replayConflictAndCrossRoundRecovery() async throws {
        let (db, task, run) = try await fixture()
        let store = TaskChecklistStore(database: db)
        let request = TaskChecklistUpdate(expectedRevision: 0, title: "Update", steps: [.init(id: "inspect", title: "Inspect", status: .inProgress)])
        let first = try await store.update(request, runID: run, operationID: "call-1")
        #expect(try await store.update(request, runID: run, operationID: "call-1") == first)
        await #expect(throws: (any Error).self) { try await store.update(request, runID: run, operationID: "call-2") }
        let nextRun = UUID()
        try await SQLiteRunStore(database: db).saveRun(.init(id: nextRun, conversationID: task, state: "running", goal: "Continue", startedAt: Date()))
        let reopened = TaskChecklistStore(database: db)
        #expect(try await reopened.latest(conversationID: task) == first)
        let second = try await reopened.update(.init(expectedRevision: 1, title: "Update", steps: [.init(id: "inspect", title: "Inspect", status: .completed, evidence: ["artifact:report.txt"])]), runID: nextRun, operationID: "call-1")
        #expect(second.revision == 2 && second.isFinished)
        #expect(try await store.latest(conversationID: task) == second)
        // A late retry returns its own original receipt, not a newer snapshot.
        #expect(try await store.update(request, runID: run, operationID: "call-1") == first)
    }

    @Test func unfinishedStepsCannotDisappearAndCompletionNeedsEvidence() async throws {
        let (db, _, run) = try await fixture()
        let store = TaskChecklistStore(database: db)
        _ = try await store.update(.init(expectedRevision: 0, title: "Work", steps: [.init(id: "a", title: "A")]), runID: run, operationID: "a")
        for startNew in [false, true] {
            await #expect(throws: (any Error).self) {
                try await store.update(.init(expectedRevision: 1, title: "Work", steps: [.init(id: "b", title: "B")], startNew: startNew), runID: run, operationID: "b")
            }
        }
        #expect(throws: (any Error).self) { try TaskChecklistUpdate(expectedRevision: 1, title: "Work", steps: [.init(id: "a", title: "A", status: .completed)]).validate() }
        let cancelled = try await store.update(.init(expectedRevision: 1, title: "Work", steps: [.init(id: "a", title: "A", status: .cancelled)]), runID: run, operationID: "cancel")
        #expect(cancelled.isFinished)
        let next = try await store.update(.init(expectedRevision: 2, title: "Next", steps: [.init(id: "b", title: "B")], startNew: true), runID: run, operationID: "new")
        #expect(next.revision == 3 && next.steps.map(\.id) == ["b"])
    }

    @Test func liveSteeringCanReorderReopenAndExtendPlan() async throws {
        let (db, task, run) = try await fixture()
        let store = TaskChecklistStore(database: db)
        _ = try await store.update(.init(expectedRevision: 0, title: "Original plan", steps: [
            .init(id: "inspect", title: "Inspect", status: .completed, evidence: ["old-report.txt"]),
            .init(id: "build", title: "Build", status: .inProgress),
            .init(id: "publish", title: "Publish")
        ]), runID: run, operationID: "initial")
        // User changes the delivery scope; fresh evidence invalidates a prior
        // result. The model revises the same plan while this run is active.
        let revised = try await store.update(.init(expectedRevision: 1, title: "Revised plan", steps: [
            .init(id: "reproduce", title: "Reproduce newly reported issue", status: .inProgress),
            .init(id: "inspect", title: "Inspect the corrected input", status: .pending),
            .init(id: "build", title: "Build after correction", status: .pending),
            .init(id: "publish", title: "Publish", status: .cancelled)
        ]), runID: run, operationID: "steering")
        let restored = try await TaskChecklistStore(database: db).latest(conversationID: task)
        #expect(restored == revised)
        #expect(revised.steps.map(\.id) == ["reproduce", "inspect", "build", "publish"])
        #expect(revised.currentStep?.id == "reproduce")
        #expect(revised.completedCount == 0 && revised.cancelledCount == 1)
        #expect(revised.revision == 2 && !revised.isFinished)
        let revisions = try await db.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_checklist_revisions WHERE conversation_id = ?", arguments: [task.uuidString])
        }
        #expect(revisions == 2)
    }

    @Test func concurrentWritersAndToolScope() async throws {
        let (db, task, run) = try await fixture()
        let store = TaskChecklistStore(database: db)
        let update = TaskChecklistUpdate(expectedRevision: 0, title: "Race", steps: [.init(id: "a", title: "A")])
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for id in ["one", "two"] {
                group.addTask { (try? await store.update(update, runID: run, operationID: id)) != nil }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(results.filter { $0 }.count == 1)
        #expect(try await store.latest(conversationID: task)?.revision == 1)
        await #expect(throws: (any Error).self) {
            try await TaskUpdatePlanTool(store: store).execute(update, context: .init(runID: run, cancellation: CancellationToken()))
        }
        await #expect(throws: (any Error).self) {
            try await TaskReadPlanTool(store: store).execute(.init(), context: .init(runID: UUID(), cancellation: CancellationToken()))
        }
        #expect(try await SQLiteIntelligenceStore(database: db).goals(conversationID: task).isEmpty)
    }

    @Test func staleRevisionErrorCarriesCurrentRevisionForImmediateRetry() async throws {
        let (db, _, run) = try await fixture()
        let store = TaskChecklistStore(database: db)
        _ = try await store.update(.init(expectedRevision: 0, title: "Work", steps: [
            .init(id: "a", title: "Inspect", status: .inProgress)
        ]), runID: run, operationID: "first")
        do {
            _ = try await store.update(.init(expectedRevision: 0, title: "Work", steps: [
                .init(id: "a", title: "Inspect", status: .completed, evidence: ["report.txt"])
            ]), runID: run, operationID: "second")
            Issue.record("Expected a stale-revision CAS failure")
        } catch {
            let message = String(describing: error)
            // The model must be able to retry immediately without readPlan.
            #expect(message.contains("current revision is 1"))
            #expect(message.contains("expectedRevision=1"))
        }
        // Retrying with the hinted revision succeeds.
        let retried = try await store.update(.init(expectedRevision: 1, title: "Work", steps: [
            .init(id: "a", title: "Inspect", status: .completed, evidence: ["report.txt"])
        ]), runID: run, operationID: "third")
        #expect(retried.revision == 2)
    }

    @Test func finishedChecklistAcceptsFreshStepsWithoutStartNew() async throws {
        let (db, _, run) = try await fixture()
        let store = TaskChecklistStore(database: db)
        let done = try await store.update(.init(title: "Day one", steps: [
            .init(id: "a", title: "A", status: .completed, evidence: ["report.txt"]),
            .init(id: "b", title: "B", status: .cancelled)
        ]), runID: run, operationID: "day-one")
        #expect(done.isFinished)
        #expect(done.lifecycleHint.contains("CHECKLIST FINISHED"))
        // A new task must not append to the finished list: fresh IDs, no startNew.
        let next = try await store.update(.init(title: "Day two", steps: [
            .init(id: "c", title: "C", status: .inProgress)
        ]), runID: run, operationID: "day-two")
        #expect(next.revision == 2 && next.steps.map(\.id) == ["c"])
        // History survives in the revisions table.
        let revisions = try await db.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_checklist_revisions WHERE conversation_id = ?", arguments: [done.conversationID.uuidString])
        }
        #expect(revisions == 2)
    }

    @Test func unfinishedChecklistLetsTerminalStepsRetireButKeepsOpenIDs() async throws {
        let (db, _, run) = try await fixture()
        let store = TaskChecklistStore(database: db)
        _ = try await store.update(.init(title: "Work", steps: [
            .init(id: "a", title: "A", status: .completed, evidence: ["a.txt"]),
            .init(id: "b", title: "B", status: .completed, evidence: ["b.txt"]),
            .init(id: "c", title: "C", status: .inProgress),
            .init(id: "d", title: "D")
        ]), runID: run, operationID: "initial")
        // Completed steps retire from the working list; open IDs must stay.
        let slimmed = try await store.update(.init(title: "Work", steps: [
            .init(id: "c", title: "C", status: .completed, evidence: ["c.txt"]),
            .init(id: "d", title: "D", status: .inProgress)
        ]), runID: run, operationID: "slim")
        #expect(slimmed.steps.map(\.id) == ["c", "d"])
        // Dropping an OPEN step fails and names exactly which IDs to carry.
        do {
            _ = try await store.update(.init(title: "Work", steps: [
                .init(id: "x", title: "X", status: .inProgress)
            ]), runID: run, operationID: "drop-open")
            Issue.record("Expected an open-step carry failure")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("d"))          // the only remaining open step
            #expect(!message.contains("\"a\""))     // settled steps are not required
        }
        // Dropping a COMPLETED step is allowed: c retires, d closes, list finishes.
        let finished = try await store.update(.init(title: "Work", steps: [
            .init(id: "d", title: "D", status: .completed, evidence: ["d.txt"])
        ]), runID: run, operationID: "finish")
        #expect(finished.steps.map(\.id) == ["d"] && finished.isFinished)
    }

    @Test func omittedRevisionWritesOverCurrentAndPreciseErrorsNameSteps() async throws {
        let (db, _, run) = try await fixture()
        let store = TaskChecklistStore(database: db)
        _ = try await store.update(.init(title: "Work", steps: [.init(id: "a", title: "A", status: .inProgress)]), runID: run, operationID: "one")
        // No expectedRevision: single-writer fast path, no CAS failure.
        let overwritten = try await store.update(.init(title: "Work", steps: [.init(id: "a", title: "A", status: .completed, evidence: ["a.txt"])]), runID: run, operationID: "two")
        #expect(overwritten.revision == 2 && overwritten.isFinished)
        // Precise validation errors name the offending steps.
        #expect(throws: (any Error).self) {
            try TaskChecklistUpdate(title: "T", steps: [
                .init(id: "a", title: "A", status: .inProgress),
                .init(id: "b", title: "B", status: .inProgress)
            ]).validate()
        }
        do {
            try TaskChecklistUpdate(title: "T", steps: [
                .init(id: "a", title: "A", status: .inProgress),
                .init(id: "b", title: "B", status: .inProgress)
            ]).validate()
        } catch {
            let message = String(describing: error)
            #expect(message.contains("a") && message.contains("b"))
        }
        do {
            try TaskChecklistUpdate(title: "T", steps: [.init(id: "a", title: "A", status: .completed)]).validate()
        } catch {
            #expect(String(describing: error).contains("marked completed"))
        }
    }

    @Test func toolOutputCarriesLifecycleHint() async throws {
        let (db, _, run) = try await fixture()
        let store = TaskChecklistStore(database: db)
        let tool = TaskUpdatePlanTool(store: store)
        let output = try await tool.execute(.init(title: "Work", steps: [
            .init(id: "a", title: "A", status: .completed, evidence: ["a.txt"])
        ]), context: .init(runID: run, toolCallID: "call-x", cancellation: CancellationToken()))
        #expect(output.summary.contains("CHECKLIST FINISHED"))
        #expect(output.summary.contains("starts a NEW checklist"))
    }
}
