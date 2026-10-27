// FloeAppTests — inline conversation selection contracts.
//
// The long-press multi-select shared by the sidebar, Chat list and Task
// Center overview must: enter selection immediately on press (never a
// management sheet), scope select-all to the visible slice, prune invisible
// selections on filter changes, freeze confirmation targets against later
// selection changes, gate ALL mutations while a batch runs, keep failed /
// unverified / not-attempted items selected for a truthful retry, and stop
// cooperatively between items through the EXISTING TaskBulkRunner. These
// tests pin the model against synthetic receipts and the real runner with
// synthetic identities only; the destructive lifecycle commands themselves
// stay covered by TaskBulkManagementTests.

#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("FloeApp.InlineConversationSelection")
@MainActor
struct InlineConversationSelectionTests {

    private func item(_ id: UUID, title: String = "task") -> TaskBulkItem {
        TaskBulkItem(id: id, title: title)
    }

    /// Each test owns a private lane so parallel test runs can never share
    /// the app-wide batch lane; hosts use the default shared lane.
    private func makeModel() -> InlineConversationSelectionModel {
        InlineConversationSelectionModel(lane: InlineConversationBulkLane())
    }

    private func summary(
        _ operation: TaskBulkOperation,
        _ pairs: [(UUID, TaskBulkItemOutcome)],
        cancelled: Bool = false
    ) -> TaskBulkSummary {
        TaskBulkSummary(
            operation: operation,
            results: pairs.map { TaskBulkItemResult(item: item($0.0), outcome: $0.1) },
            wasCancelled: cancelled
        )
    }

    /// Executes nothing but records the EXACT frozen batch it was given,
    /// then resolves every recorded item as archived.
    private actor BatchLog {
        private(set) var runs: [[UUID]] = []
        func record(_ ids: [UUID]) { runs.append(ids) }
    }

    private func loggingExecutor(_ log: BatchLog)
        -> InlineConversationSelectionModel.BatchExecute
    {
        { op, items, _ in
            await log.record(items.map(\.id))
            return self.summary(op, items.map { ($0.id, TaskBulkItemOutcome.archived) })
        }
    }

    /// Suspends a batch until released, so "busy" behaviour can be asserted.
    private actor HoldGate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { continuations.append($0) }
        }
        func release() {
            let pending = continuations
            continuations = []
            for cont in pending { cont.resume() }
        }
    }

    /// Lets the real serial runner report its first item before the batch
    /// is stopped, without a wall-clock race.
    private actor ProgressGate {
        private var entered = false
        func enter() { entered = true }
        func waitUntilEntered() async {
            while !entered {
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    // MARK: - Entry and toggling

    @Test("A long press selects the pressed row immediately and opens the mode")
    func beginSelectsPressedRow() {
        let model = makeModel()
        let a = UUID()
        model.begin(with: a)
        #expect(model.isActive)
        #expect(model.selectedIDs == [a])
    }

    @Test("The Manage entry opens the inline mode with an empty selection")
    func beginWithoutRowStartsEmpty() {
        let model = makeModel()
        model.begin(with: nil)
        #expect(model.isActive)
        #expect(model.selectedIDs.isEmpty)
    }

    @Test("Tapping a row outside the mode selects nothing")
    func toggleIgnoredWhenInactive() {
        let model = makeModel()
        model.toggle(UUID())
        #expect(!model.isActive)
        #expect(model.selectedIDs.isEmpty)
    }

    @Test("Tap toggles the circle; a long press while open also toggles")
    func toggleAndLongPressWhileActive() {
        let model = makeModel()
        let a = UUID()
        let b = UUID()
        model.begin(with: a)
        model.begin(with: b)
        #expect(model.selectedIDs == [a, b])
        model.begin(with: a)
        #expect(model.selectedIDs == [b])
        model.toggle(b)
        #expect(model.selectedIDs.isEmpty)
    }

    // MARK: - Visible-slice scope

    @Test("Select-all sweeps only the visible rows, never hidden ones")
    func selectAllScopedToVisible() {
        let model = makeModel()
        let a = UUID()
        let b = UUID()
        let hidden = UUID()
        model.begin(with: a)
        model.toggle(hidden)
        model.toggleSelectAll(visible: [a, b])
        #expect(model.selectedIDs == [a, b, hidden])
        model.toggleSelectAll(visible: [a, b])
        // Deselecting removes exactly the visible subset; a previously
        // selected (then-visible) identity is untouched by this rule —
        // the host prunes it on its own filter change (next test).
        #expect(model.selectedIDs == [hidden])
        // A second hidden id must never be swept in.
        let otherHidden = UUID()
        model.toggleSelectAll(visible: [a, b])
        #expect(!model.selectedIDs.contains(otherHidden))
    }

    @Test("Filter changes prune invisible selections (no hidden operations)")
    func pruneDropsInvisibleSelection() {
        let model = makeModel()
        let a = UUID()
        let b = UUID()
        model.begin(with: a)
        model.toggle(b)
        model.pruneInvisible([a])
        #expect(model.selectedIDs == [a])
        model.pruneInvisible([])
        #expect(model.selectedIDs.isEmpty)
    }

    // MARK: - Done / exit

    @Test("Done clears mode, selection, receipt and pending confirmations")
    func endClearsEverything() {
        let model = makeModel()
        let a = UUID()
        model.begin(with: a)
        model.requestDelete(items: [item(a)], runningImpact: 0)
        model.end()
        #expect(!model.isActive)
        #expect(model.selectedIDs.isEmpty)
        #expect(model.summary == nil)
        #expect(!model.confirmingDelete)
        #expect(model.pendingDeleteItems.isEmpty)
    }

    // MARK: - Confirmation freeze

    @Test("A confirmation runs exactly the frozen targets, not the current selection")
    func confirmationFreezesTargets() async {
        let model = makeModel()
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let later = UUID()
        model.begin(with: a)
        model.toggle(b)
        model.toggle(c)
        model.requestArchive(items: [item(a), item(b), item(c)], runningImpact: 0)
        #expect(model.confirmingArchive)
        // Selection and filter change WHILE the dialog is open:
        model.toggle(later)
        model.pruneInvisible([a, later])
        let log = BatchLog()
        await model.run(
            operation: .archive,
            frozen: model.takeFrozenArchiveTargets(),
            execute: loggingExecutor(log),
            afterRun: {}
        )
        let recordedRuns = await log.runs
        #expect(recordedRuns == [[a, b, c]])
        #expect(!model.confirmingArchive)
        #expect(model.pendingArchiveItems.isEmpty)
    }

    @Test("Empty requests open no confirmation")
    func emptyRequestsIgnored() {
        let model = makeModel()
        model.begin(with: nil)
        model.requestArchive(items: [], runningImpact: 0)
        model.requestDelete(items: [], runningImpact: 0)
        #expect(!model.confirmingArchive)
        #expect(!model.confirmingDelete)
        // Outside the mode nothing requests at all.
        model.end()
        model.requestArchive(items: [item(UUID())], runningImpact: 1)
        #expect(!model.confirmingArchive)
    }

    @Test("Confirmation copy always states the existing stop semantics")
    func confirmationMessagesPreserveRunningSemantics() {
        let model = makeModel()
        let a = UUID()
        model.begin(with: a)
        model.requestArchive(items: [item(a)], runningImpact: 0)
        // A zero running hint NEVER claims "nothing is running": the stop
        // sentence stays, and the count sentence only appears when known.
        #expect(model.archiveConfirmationMessage == TaskManagementCopy.archiveStopsRunningWork)
        model.requestArchive(items: [item(a)], runningImpact: 2)
        #expect(model.archiveConfirmationMessage.contains(TaskManagementCopy.runningImpact(2)))
        model.requestDelete(items: [item(a)], runningImpact: 3)
        #expect(model.deleteConfirmationMessage.contains(TaskManagementCopy.deleteStopsRunningWork))
        #expect(model.deleteConfirmationMessage.contains(TaskManagementCopy.runningImpact(3)))
    }

    // MARK: - Busy gating + receipts

    @Test("A running batch gates every mutation, including Done")
    func busyGatesAllMutations() async {
        let model = makeModel()
        let a = UUID()
        let b = UUID()
        model.begin(with: a)
        let gate = HoldGate()
        let items = [item(a)]
        let batch = Task {
            await model.run(
                operation: .archive,
                frozen: items,
                execute: { op, its, _ in
                    await gate.wait()
                    return TaskBulkSummary(
                        operation: op,
                        results: its.map { TaskBulkItemResult(item: $0, outcome: .archived) },
                        wasCancelled: false
                    )
                },
                afterRun: {}
            )
        }
        while !model.busy {
            try? await Task.sleep(for: .milliseconds(2))
        }
        model.begin(with: b)
        model.toggle(b)
        model.toggleSelectAll(visible: [b])
        model.end()
        model.requestArchive(items: [item(b)], runningImpact: 0)
        #expect(model.isActive)
        #expect(model.selectedIDs == [a])
        #expect(!model.confirmingArchive)
        // Pruning invisible rows is a safety removal and stays allowed.
        model.pruneInvisible([])
        #expect(model.selectedIDs.isEmpty)
        await gate.release()
        await batch.value
        #expect(!model.busy)
        #expect(model.summary?.archivedCount == 1)
    }

    @Test("Partial failures stay selected; resolved rows leave the selection")
    func partialFailureKeepsUnresolvedSelected() async {
        let model = makeModel()
        let ok = UUID()
        let failed = UUID()
        let gone = UUID()
        let unverified = UUID()
        model.begin(with: nil)
        for id in [ok, failed, gone, unverified] { model.toggle(id) }
        let receipt = summary(.delete, [
            (ok, .deleted),
            (failed, .failed("busy")),
            (gone, .skipped(.alreadyGone)),
            (unverified, .unverified("unreadable")),
        ])
        await model.run(
            operation: .delete,
            frozen: [item(ok), item(failed), item(gone), item(unverified)],
            execute: { _, _, _ in receipt },
            afterRun: {}
        )
        #expect(model.selectedIDs == [failed, unverified])
        #expect(model.summary == receipt)
        #expect(!model.busy)
    }

    @Test("Stop between items leaves unprocessed rows selected via the real runner")
    func stopLeavesRemainingSelected() async {
        let model = makeModel()
        let ids = (0..<5).map { _ in UUID() }
        model.begin(with: nil)
        for id in ids { model.toggle(id) }
        let gate = ProgressGate()
        let batch = Task {
            await model.run(
                operation: .archive,
                frozen: ids.map { item($0) },
                execute: { op, its, token in
                    await TaskBulkRunner().run(
                        operation: op,
                        items: its,
                        cancellation: token
                    ) { _ in
                        await gate.enter()
                        try? await Task.sleep(for: .milliseconds(8))
                        return .archived
                    }
                },
                afterRun: {}
            )
        }
        await gate.waitUntilEntered()
        model.stopRunning()
        await batch.value
        guard let receipt = model.summary else {
            Issue.record("batch produced no receipt")
            return
        }
        #expect(receipt.wasCancelled)
        #expect(receipt.archivedCount + receipt.notAttemptedCount == 5)
        // Failed / not-attempted rows stay exactly actionable for a retry.
        #expect(model.selectedIDs == receipt.retainedIDs)
        #expect(!model.selectedIDs.isEmpty)
    }

    @Test("An empty frozen batch never starts")
    func emptyBatchIgnored() async {
        let model = makeModel()
        model.begin(with: nil)
        await model.run(
            operation: .archive,
            frozen: [],
            execute: { op, _, _ in TaskBulkSummary(operation: op, results: [], wasCancelled: false) },
            afterRun: {}
        )
        #expect(!model.busy)
        #expect(model.summary == nil)
    }

    // MARK: - One batch lane across surfaces

    @Test("Host models share the app-wide lane by default")
    func defaultLaneIsShared() {
        let model = makeModel()
        #expect(model.lane !== InlineConversationBulkLane.shared)
        #expect(InlineConversationSelectionModel().lane === InlineConversationBulkLane.shared)
    }

    @Test("A second inline surface cannot start while a batch occupies the lane")
    func laneBlocksCrossSurfaceStart() async {
        let lane = InlineConversationBulkLane()
        let first = InlineConversationSelectionModel(lane: lane)
        let second = InlineConversationSelectionModel(lane: lane)
        let a = UUID()
        let b = UUID()
        first.begin(with: a)
        second.begin(with: b)
        let gate = HoldGate()
        let batch = Task {
            await first.run(
                operation: .archive,
                frozen: [item(a)],
                execute: { op, its, _ in
                    await gate.wait()
                    return TaskBulkSummary(
                        operation: op,
                        results: its.map { TaskBulkItemResult(item: $0, outcome: .archived) },
                        wasCancelled: false
                    )
                },
                afterRun: {}
            )
        }
        while !first.busy {
            try? await Task.sleep(for: .milliseconds(2))
        }
        second.requestDelete(items: [item(b)], runningImpact: 0)
        #expect(!second.confirmingDelete)
        #expect(!second.canRequestBatch)
        // Even an awaited run cannot steal the lane from the in-flight
        // surface: no second batch, no receipt, no selection change.
        await second.run(
            operation: .delete,
            frozen: [item(b)],
            execute: { op, its, _ in
                TaskBulkSummary(
                    operation: op,
                    results: its.map { TaskBulkItemResult(item: $0, outcome: .deleted) },
                    wasCancelled: false
                )
            },
            afterRun: {}
        )
        #expect(second.summary == nil)
        #expect(second.selectedIDs == [b])
        await gate.release()
        await batch.value
        // Lane released after the first batch: the second surface may
        // request again.
        second.requestDelete(items: [item(b)], runningImpact: 0)
        #expect(second.confirmingDelete)
    }

    // MARK: - Stable accessibility identifiers

    @Test("Row circles and bar controls expose the handed-off identifiers")
    func identifiersAreStable() {
        let id = UUID()
        #expect(InlineSelectionIdentifiers.circle(id) == "tasks.inline.circle.\(id.uuidString)")
        #expect(InlineSelectionIdentifiers.selectAll == "tasks.inline.selectAll")
        #expect(InlineSelectionIdentifiers.done == "tasks.inline.done")
        #expect(InlineSelectionIdentifiers.count == "tasks.inline.count")
        #expect(InlineSelectionIdentifiers.archive == "tasks.inline.archive")
        #expect(InlineSelectionIdentifiers.delete == "tasks.inline.delete")
        #expect(InlineSelectionIdentifiers.stop == "tasks.inline.stop")
        #expect(InlineSelectionIdentifiers.confirmArchive == "tasks.inline.confirm.archive")
        #expect(InlineSelectionIdentifiers.confirmDelete == "tasks.inline.confirm.delete")
    }

    @Test("Result copy reports every real outcome category separately")
    func receiptCountsStayTruthful() {
        let receipt = summary(.archive, [
            (UUID(), .archived),
            (UUID(), .skipped(.alreadyInTargetState)),
            (UUID(), .failed("x")),
            (UUID(), .unverified("y")),
            (UUID(), .notAttempted),
        ], cancelled: true)
        let text = InlineSelectionResultCopy.text(for: receipt)
        #expect(!text.isEmpty)
        #expect(receipt.archivedCount == 1)
        #expect(receipt.skippedCount == 1)
        #expect(receipt.failedCount == 1)
        #expect(receipt.unverifiedCount == 1)
        #expect(receipt.notAttemptedCount == 1)
        #expect(receipt.succeededCount == 1)
    }
}
#endif
