import Foundation
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
}
