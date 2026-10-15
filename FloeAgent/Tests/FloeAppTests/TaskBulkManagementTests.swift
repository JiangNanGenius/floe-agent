// FloeAppTests — canonical task management contracts.
//
// The management surface (Task Center / Settings > Data Management / run
// history) composes the EXISTING single-target lifecycle commands through a
// pure bounded-serial engine (`TaskBulkRunner` + selection rules). These
// tests pin the destructive boundaries with synthetic fixtures: archive /
// restore / multi-delete outcomes, cancel / failure / partial results,
// duplicate and stale identities, retry-never-replays, selection scope — and
// an isolated in-memory database proving what a task delete must leave
// alone (independent project workspaces, document-assistant conversations
// and other conversations' runs).

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.TaskBulkManagement")
struct TaskBulkManagementTests {

    // MARK: - Fixtures

    private func items(_ count: Int) -> [TaskBulkItem] {
        (0..<count).map { TaskBulkItem(id: UUID(), title: "task \($0)") }
    }

    /// Measures the maximum number of concurrently running performers.
    private actor ConcurrencyProbe {
        private(set) var active = 0
        private(set) var peak = 0
        func enter() {
            active += 1
            peak = max(peak, active)
        }
        func leave() { active -= 1 }
    }

    private actor CallLog {
        private(set) var called: [UUID] = []
        private(set) var stages: [String] = []
        func record(_ id: UUID) { called.append(id) }
        func record(_ id: UUID, stage: String) {
            called.append(id)
            stages.append(stage)
        }
    }

    // MARK: - Bounded serial execution

    @Test("A bulk delete runs strictly one task at a time, in submission order")
    func deleteIsBoundedSerial() async {
        let list = items(4)
        let probe = ConcurrencyProbe()
        let log = CallLog()
        let summary = await TaskBulkRunner().run(operation: .delete, items: list) { item in
            await probe.enter()
            await log.record(item.id)
            await Task.yield()
            await probe.leave()
            return .deleted
        }
        #expect(await probe.peak == 1)
        #expect(await log.called == list.map(\.id))
        #expect(summary.deletedCount == 4)
        #expect(summary.removedIDs == Set(list.map(\.id)))
        #expect(summary.retainedIDs.isEmpty)
    }

    @Test("Duplicate conversation identities are acted on once")
    func duplicateIdentitiesRunOnce() async {
        let id = UUID()
        let list = [TaskBulkItem(id: id, title: "a"), TaskBulkItem(id: id, title: "a")]
        let log = CallLog()
        let summary = await TaskBulkRunner().run(operation: .delete, items: list) { item in
            await log.record(item.id)
            return .deleted
        }
        #expect(await log.called == [id])
        #expect(summary.results.count == 1)
        #expect(summary.deletedCount == 1)
    }

    // MARK: - Partial / failure / skip / cancel results

    @Test("A partial failure removes only the resolved tasks and keeps the failed one actionable")
    func partialFailureKeepsOnlyFailedSelected() async {
        let list = items(3)
        let failedID = list[1].id
        let summary = await TaskBulkRunner().run(operation: .delete, items: list) { item in
            item.id == failedID ? .failed("busy") : .deleted
        }
        #expect(summary.deletedCount == 2)
        #expect(summary.failedCount == 1)
        #expect(summary.removedIDs == [list[0].id, list[2].id])
        #expect(summary.retainedIDs == [failedID])
        #expect(summary.failedItems.map(\.id) == [failedID])
        #expect(summary.failedItems.first?.outcome.failureText == "busy")
    }

    @Test("Stale identities are reported as skipped, never as deleted")
    func staleIdentitiesAreSkipped() async {
        let list = items(2)
        let summary = await TaskBulkRunner().run(operation: .delete, items: list) { item in
            item.id == list[0].id ? .skipped(.alreadyGone) : .deleted
        }
        #expect(summary.skippedCount == 1)
        #expect(summary.deletedCount == 1)
        #expect(summary.succeededCount == 1)
        #expect(summary.removedIDs == Set(list.map(\.id)))
        #expect(summary.retainedIDs.isEmpty)
    }

    @Test("Archive and restore batches report their own outcomes")
    func archiveAndRestoreOutcomes() async {
        let list = items(2)
        let archived = await TaskBulkRunner().run(operation: .archive, items: list) { _ in .archived }
        #expect(archived.archivedCount == 2)
        #expect(archived.deletedCount == 0)
        let restored = await TaskBulkRunner().run(operation: .restore, items: list) { _ in .restored }
        #expect(restored.restoredCount == 2)
    }

    @Test("Cancellation between items keeps every unprocessed task retained, never resolved")
    func cancellationStopsBetweenItems() async {
        let list = items(3)
        let token = TaskBulkCancellationToken()
        let summary = await TaskBulkRunner().run(operation: .delete, items: list, cancellation: token) { item in
            token.cancel()
            return .deleted
        }
        #expect(summary.deletedCount == 1)
        #expect(summary.notAttemptedCount == 2)
        #expect(summary.wasCancelled)
        #expect(summary.removedIDs == [list[0].id])
        #expect(summary.retainedIDs == [list[1].id, list[2].id])
    }

    @Test("A pre-cancelled batch performs nothing")
    func preCancelledBatchDoesNothing() async {
        let list = items(2)
        let token = TaskBulkCancellationToken()
        token.cancel()
        let log = CallLog()
        let summary = await TaskBulkRunner().run(operation: .delete, items: list, cancellation: token) { item in
            await log.record(item.id)
            return .deleted
        }
        #expect(await log.called.isEmpty)
        #expect(summary.notAttemptedCount == 2)
        #expect(summary.removedIDs.isEmpty)
    }

    // MARK: - Tri-state durable reads (only a successful read decides)

    @Test("A failed read is never treated as gone or as success")
    func readFailureIsNeverGoneOrSuccess() {
        let unreadable = TaskBulkRowState.unreadable("read")
        for operation in [TaskBulkOperation.archive, .restore, .delete] {
            #expect(TaskBulkDecision.preflight(operation: operation, state: unreadable) == .unverified("read"))
            #expect(TaskBulkDecision.afterFailure(operation: operation, state: unreadable, errorText: "err") == .unverified("read"))
        }
        #expect(TaskBulkDecision.preflight(operation: .delete, state: .missing) == .skipped(.alreadyGone))
        #expect(TaskBulkDecision.afterFailure(operation: .delete, state: .missing, errorText: "err") == .deleted)
        #expect(TaskBulkDecision.afterFailure(
            operation: .delete,
            state: .present(archived: false, ordinary: true),
            errorText: "err"
        ) == .failed("err"))
        #expect(TaskBulkDecision.afterFailure(
            operation: .archive,
            state: .present(archived: true, ordinary: true),
            errorText: "err"
        ) == .archived)
        #expect(TaskBulkDecision.afterFailure(
            operation: .archive,
            state: .present(archived: false, ordinary: true),
            errorText: "err"
        ) == .failed("err"))
        #expect(TaskBulkDecision.afterFailure(
            operation: .restore,
            state: .present(archived: false, ordinary: true),
            errorText: "err"
        ) == .restored)
        #expect(TaskBulkDecision.preflight(
            operation: .delete,
            state: .present(archived: false, ordinary: false)
        ) == .skipped(.notManagedHere))
    }

    @Test("Unverified items stay retained and are counted separately")
    func unverifiedItemsStayRetained() async {
        let list = items(3)
        let summary = await TaskBulkRunner().run(operation: .delete, items: list) { item in
            switch item.id {
            case list[0].id: return .deleted
            case list[1].id: return .unverified("read")
            default: return .failed("busy")
            }
        }
        #expect(summary.deletedCount == 1)
        #expect(summary.unverifiedCount == 1)
        #expect(summary.failedCount == 1)
        #expect(summary.succeededCount == 1)
        #expect(summary.skippedCount == 0)
        #expect(summary.removedIDs == [list[0].id])
        #expect(summary.retainedIDs == [list[1].id, list[2].id])
        #expect(summary.unresolvedItems.map(\.id) == [list[1].id, list[2].id])
        #expect(!TaskBulkItemOutcome.unverified("read").isResolved)
    }

    @Test("A retry never replays a resolved identity")
    func retryNeverReplaysResolved() async {
        let list = items(2)
        let log = CallLog()
        let first = await TaskBulkRunner().run(operation: .delete, items: list) { item in
            await log.record(item.id)
            return item.id == list[0].id ? .deleted : .failed("busy")
        }
        let second = await TaskBulkRunner().run(
            operation: .delete,
            items: list,
            excluding: first.removedIDs
        ) { item in
            await log.record(item.id)
            return .deleted
        }
        #expect(await log.called == [list[0].id, list[1].id, list[1].id])
        #expect(second.deletedCount == 1)
        #expect(second.removedIDs == [list[1].id])
    }

    /// The UI-previous bug: one lifetime `completedIDs` set was passed as the
    /// exclusion of EVERY later operation, so after archiving task A a later,
    /// separately confirmed Restore A (or Delete A) was silently skipped.
    /// Exclusion is only ever the resolved remainder of ONE batch; a new
    /// operation has its own authority and must run.
    @Test("The same identity can be archived, restored, archived again and deleted in one session")
    func sameIdentityIsNotExcludedAcrossSeparateOperations() async {
        let item = items(1)[0]
        let log = CallLog()

        let archived = await TaskBulkRunner().run(operation: .archive, items: [item]) { _ in
            await log.record(item.id, stage: "archive-1")
            return .archived
        }
        #expect(archived.removedIDs == [item.id])

        // Separate operation, no lifetime exclusion: it must run.
        let restored = await TaskBulkRunner().run(operation: .restore, items: [item]) { _ in
            await log.record(item.id, stage: "restore")
            return .restored
        }
        #expect(restored.removedIDs == [item.id])

        // Archive again after the restore: same identity, new operation.
        let rearchived = await TaskBulkRunner().run(operation: .archive, items: [item]) { _ in
            await log.record(item.id, stage: "archive-2")
            return .archived
        }
        #expect(rearchived.removedIDs == [item.id])

        // Restore -> delete in the same open management session.
        let listed = await TaskBulkRunner().run(operation: .restore, items: [item]) { _ in
            await log.record(item.id, stage: "restore-2")
            return .restored
        }
        #expect(listed.removedIDs == [item.id])
        let deleted = await TaskBulkRunner().run(operation: .delete, items: [item]) { _ in
            await log.record(item.id, stage: "delete")
            return .deleted
        }
        #expect(deleted.removedIDs == [item.id])
        #expect(await log.stages == ["archive-1", "restore", "archive-2", "restore-2", "delete"])
    }

    // MARK: - Selection scope

    @Test("Select-all only ever touches the visible slice")
    func selectAllIsScopedToVisible() {
        let a = UUID(), b = UUID(), hidden = UUID()
        var selection: Set<UUID> = [a]
        selection = TaskBulkSelectionRules.selectionAfterSelectAllToggle(selection, visible: [a, b])
        #expect(selection == [a, b])
        selection = TaskBulkSelectionRules.selectionAfterSelectAllToggle(selection, visible: [a, b])
        #expect(selection.isEmpty)
        // A hidden task can never be swept in by select-all.
        selection = TaskBulkSelectionRules.selectionAfterSelectAllToggle([hidden], visible: [a])
        #expect(selection == [hidden, a])
        #expect(!selection.contains(where: { $0 == b }))
    }

    @Test("Empty visible slice leaves the selection untouched")
    func selectAllOnEmptyVisibleIsNoOp() {
        let a = UUID()
        #expect(TaskBulkSelectionRules.selectionAfterSelectAllToggle([a], visible: []) == [a])
        #expect(!TaskBulkSelectionRules.allVisibleSelected([a], visible: []))
    }

    @Test("Pruning drops disappearing and hidden tasks, toggling is symmetric")
    func pruningAndToggling() {
        let a = UUID(), b = UUID()
        var selection: Set<UUID> = [a, b]
        selection = TaskBulkSelectionRules.pruned(selection, to: [b])
        #expect(selection == [b])
        selection = TaskBulkSelectionRules.toggled(selection, id: b)
        #expect(selection.isEmpty)
        selection = TaskBulkSelectionRules.toggled(selection, id: a)
        #expect(selection == [a])
        #expect(TaskBulkSelectionRules.allVisibleSelected([a], visible: [a]))
        #expect(!TaskBulkSelectionRules.allVisibleSelected([a], visible: [a, b]))
    }

    // MARK: - Durable retention boundaries (isolated in-memory database)

    private func makeDatabase() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    @Test("Deleting a task keeps an independent project workspace and its ownership link goes away")
    func projectWorkspaceSurvivesTaskDeletion() async throws {
        let database = try await makeDatabase()
        let conversations = SQLiteConversationStore(database: database)
        let workspaces = SQLiteWorkspaceStore(database: database)

        let project = WorkspaceRecord(name: "独立项目", rootBookmark: Data(), kind: .project)
        try await workspaces.saveWorkspace(project)
        let task = ConversationRecord(
            id: UUID(), title: "合成任务", createdAt: Date(), updatedAt: Date()
        )
        try await conversations.saveConversation(task)
        try await workspaces.assignConversation(workspaceID: project.id, conversationID: task.id)

        try await conversations.deleteConversation(id: task.id)

        #expect(try await conversations.conversation(id: task.id) == nil)
        #expect(try await workspaces.workspace(id: project.id) != nil)
        #expect(try await workspaces.workspaceID(conversationID: task.id) == nil)
        // Only a private-task workspace may be queued for file cleanup; the
        // project workspace must never appear here.
        let cleanup = try await workspaces.pendingLocalCleanup()
        #expect(!cleanup.contains { $0.workspaceID == project.id })
    }

    @Test("Only the deleted task's private workspace is queued for cleanup")
    func privateWorkspaceCleanupIsScopedToItsTask() async throws {
        let database = try await makeDatabase()
        let conversations = SQLiteConversationStore(database: database)
        let workspaces = SQLiteWorkspaceStore(database: database)

        let privateA = WorkspaceRecord(
            name: "A", rootBookmark: Data(), kind: .privateTask,
            internalRelativePath: "tasks/A"
        )
        let privateB = WorkspaceRecord(
            name: "B", rootBookmark: Data(), kind: .privateTask,
            internalRelativePath: "tasks/B"
        )
        try await workspaces.saveWorkspace(privateA)
        try await workspaces.saveWorkspace(privateB)
        let taskA = ConversationRecord(id: UUID(), title: "A", createdAt: Date(), updatedAt: Date())
        let taskB = ConversationRecord(id: UUID(), title: "B", createdAt: Date(), updatedAt: Date())
        try await conversations.saveConversation(taskA)
        try await conversations.saveConversation(taskB)
        try await workspaces.assignConversation(workspaceID: privateA.id, conversationID: taskA.id)
        try await workspaces.assignConversation(workspaceID: privateB.id, conversationID: taskB.id)

        try await conversations.deleteConversation(id: taskA.id)

        let cleanup = try await workspaces.pendingLocalCleanup()
        #expect(cleanup.contains { $0.workspaceID == privateA.id })
        #expect(!cleanup.contains { $0.workspaceID == privateB.id })
        // The other task and its workspace link are untouched.
        #expect(try await conversations.conversation(id: taskB.id) != nil)
        #expect(try await workspaces.workspaceID(conversationID: taskB.id) == privateB.id)
    }

    @Test("Deleting one task removes its runs and keeps every other task's runs")
    func runsAreScopedToTheirTask() async throws {
        let database = try await makeDatabase()
        let conversations = SQLiteConversationStore(database: database)
        let runs = SQLiteRunStore(database: database)

        let taskA = ConversationRecord(id: UUID(), title: "A", createdAt: Date(), updatedAt: Date())
        let taskB = ConversationRecord(id: UUID(), title: "B", createdAt: Date(), updatedAt: Date())
        try await conversations.saveConversation(taskA)
        try await conversations.saveConversation(taskB)
        let runA = RunRecord(
            id: UUID(), conversationID: taskA.id, state: "completed",
            goal: "A", startedAt: Date()
        )
        let runB = RunRecord(
            id: UUID(), conversationID: taskB.id, state: "completed",
            goal: "B", startedAt: Date()
        )
        try await runs.saveRun(runA)
        try await runs.saveRun(runB)

        try await conversations.deleteConversation(id: taskA.id)

        #expect(try await runs.runs(conversationID: taskA.id).isEmpty)
        #expect(try await runs.run(id: runB.id) != nil)
    }

    @Test("The task list never exposes document-assistant conversations")
    func notesConversationsStayOutOfTaskManagement() async throws {
        let database = try await makeDatabase()
        let conversations = SQLiteConversationStore(database: database)
        let notes = ConversationRecord(
            id: UUID(), title: "手记助手", createdAt: Date(), updatedAt: Date(),
            purpose: .notes
        )
        try await conversations.saveConversation(notes)
        #expect(try await conversations.conversations(includeArchived: true).isEmpty)
    }

    @Test("Archive hides a task from the active list and restore brings it back")
    func archiveAndRestoreStayReversible() async throws {
        let database = try await makeDatabase()
        let conversations = SQLiteConversationStore(database: database)
        let task = ConversationRecord(id: UUID(), title: "A", createdAt: Date(), updatedAt: Date())
        try await conversations.saveConversation(task)

        try await conversations.setArchived(id: task.id, archived: true)
        #expect(try await conversations.conversations(includeArchived: false).isEmpty)
        let archivedList = try await conversations.conversations(includeArchived: true)
        #expect(archivedList.map(\.id) == [task.id])
        #expect(archivedList.first?.archivedAt != nil)

        try await conversations.setArchived(id: task.id, archived: false)
        #expect(try await conversations.conversations(includeArchived: false).map(\.id) == [task.id])
    }
}
#endif
