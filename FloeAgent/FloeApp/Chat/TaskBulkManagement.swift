// FloeApp — Task bulk management engine (pure, dependency-free).
//
// SPDX-License-Identifier: MPL-2.0
//
// Conversation-level bulk management vocabulary and the bounded serial
// executor shared by every management entry point (Task Center, Settings >
// Data Management, run history). One item is one TASK identity
// (`ConversationRecord.id`). A task owns zero or more `RunRecord`s, but a
// bulk archive/restore/delete acts on the task exactly once — a single run or
// a duplicate id never produces a second action.
//
// The engine is deliberately pure Foundation logic: the App service
// (`ConversationTaskBulkService`) composes the EXISTING single-target
// `ConversationCenter` commands through it. There is no second store, queue,
// executor or permission path, no parallel execution (one item at a time,
// submission order), and every item reports its own truthful outcome.

import Foundation

/// The user-visible management action. The operation never changes the
/// lifecycle semantics of the existing single-target commands; it only
/// selects how many tasks a single tap processes.
enum TaskBulkOperation: Sendable, Hashable {
    case archive
    case restore
    case delete
}

/// Why an item was resolved without running the operation.
enum TaskBulkSkipReason: Sendable, Hashable {
    /// The task row no longer exists (deleted elsewhere, or the selection was
    /// stale); nothing to do and nothing to retry.
    case alreadyGone
    /// The row exists and is already in the operation's target state.
    case alreadyInTargetState
    /// The row exists but is not an ordinary managed task (for example a
    /// document-assistant conversation); management never touches it.
    case notManagedHere
}

/// The real outcome of one submitted item.
enum TaskBulkItemOutcome: Sendable, Hashable {
    case archived
    case restored
    case deleted
    case skipped(TaskBulkSkipReason)
    /// Attempted; the operation did not complete. The reason is display-ready
    /// copy (never an internal identifier) and the item stays actionable.
    case failed(String)
    /// Attempted, but the durable state could NOT be proven (the command
    /// failed AND the verification read failed). Never reported as success or
    /// as gone; the item stays actionable for a truthful retry.
    case unverified(String)
    /// The batch was cancelled before this item ran.
    case notAttempted
}

/// Tri-state durable row read. A FAILED read is deliberately neither
/// "present" nor "gone": collapsing it into "gone" would silently skip a real
/// task, and collapsing it into "present" would fabricate a failure. Only a
/// successful read can prove existence or absence.
enum TaskBulkRowState: Sendable, Hashable {
    case present(archived: Bool, ordinary: Bool)
    case missing
    case unreadable(String)
}

/// Pure decision table shared by the App service and its tests.
enum TaskBulkDecision {
    /// What the initial durable read decides before any command runs.
    /// `nil` means the operation should be attempted.
    static func preflight(operation: TaskBulkOperation, state: TaskBulkRowState) -> TaskBulkItemOutcome? {
        switch state {
        case .missing:
            return .skipped(.alreadyGone)
        case .unreadable(let reason):
            return .unverified(reason)
        case .present(let archived, let ordinary):
            guard ordinary else { return .skipped(.notManagedHere) }
            switch operation {
            case .archive:
                return archived ? .skipped(.alreadyInTargetState) : nil
            case .restore:
                return archived ? nil : .skipped(.alreadyInTargetState)
            case .delete:
                return nil
            }
        }
    }

    /// What a fresh durable read proves after the command threw. The error
    /// text is only used when the read proves the operation did not complete.
    static func afterFailure(
        operation: TaskBulkOperation,
        state: TaskBulkRowState,
        errorText: String
    ) -> TaskBulkItemOutcome {
        switch state {
        case .missing:
            // The row is provably gone: a delete really completed; an
            // archive/restore target vanished concurrently.
            return operation == .delete ? .deleted : .skipped(.alreadyGone)
        case .unreadable(let reason):
            return .unverified(reason)
        case .present(let archived, _):
            switch operation {
            case .archive:
                return archived ? .archived : .failed(errorText)
            case .restore:
                return archived ? .failed(errorText) : .restored
            case .delete:
                return .failed(errorText)
            }
        }
    }
}

/// One submitted task. `id` is the conversation identity — never a run id.
struct TaskBulkItem: Sendable, Hashable, Identifiable {
    let id: UUID
    let title: String

    init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

/// One item's result, in submission order.
struct TaskBulkItemResult: Sendable, Hashable, Identifiable {
    let item: TaskBulkItem
    let outcome: TaskBulkItemOutcome

    var id: UUID { item.id }
}

/// Aggregated outcome of one batch. `removedIDs`/`retainedIDs` drive the
/// selection update: resolved items leave the selection, unresolved items
/// stay selected so a retry can pick up exactly where the batch stopped.
struct TaskBulkSummary: Sendable, Hashable {
    let operation: TaskBulkOperation
    let results: [TaskBulkItemResult]
    /// True when the batch was stopped (by the user) before every item ran.
    let wasCancelled: Bool

    var isEmpty: Bool { results.isEmpty }

    var archivedCount: Int { count(outcomes: [.archived]) }
    var restoredCount: Int { count(outcomes: [.restored]) }
    var deletedCount: Int { count(outcomes: [.deleted]) }
    var skippedCount: Int {
        results.reduce(0) { total, result in
            if case .skipped = result.outcome { return total + 1 }
            return total
        }
    }
    var failedCount: Int {
        results.reduce(0) { total, result in
            if case .failed = result.outcome { return total + 1 }
            return total
        }
    }
    var notAttemptedCount: Int { count(outcomes: [.notAttempted]) }
    /// Attempted but unprovable (command failed AND verification read
    /// failed). Never counted as success, failure or skip.
    var unverifiedCount: Int {
        results.reduce(0) { total, result in
            if case .unverified = result.outcome { return total + 1 }
            return total
        }
    }

    var succeededCount: Int { archivedCount + restoredCount + deletedCount }

    /// Resolved identities: the task was acted on or provably needs no
    /// action. They must leave the selection.
    var removedIDs: Set<UUID> {
        Set(results.filter(\.outcome.isResolved).map(\.item.id))
    }

    /// Unresolved identities: failed or never attempted. They stay selected
    /// so the next tap retries only these, never the completed ones.
    var retainedIDs: Set<UUID> {
        Set(results.filter { !$0.outcome.isResolved }.map(\.item.id))
    }

    /// Failed and unverified items, in submission order: everything the list
    /// should show with its display-ready reason.
    var unresolvedItems: [TaskBulkItemResult] {
        results.filter { $0.outcome.issueText != nil }
    }

    var failedItems: [TaskBulkItemResult] {
        results.filter { if case .failed = $0.outcome { return true } else { return false } }
    }

    private func count(outcomes: Set<TaskBulkItemOutcome>) -> Int {
        results.reduce(0) { total, result in
            outcomes.contains(result.outcome) ? total + 1 : total
        }
    }
}

extension TaskBulkItemOutcome {
    /// A resolved outcome neither needs a retry nor keeps the task selected.
    /// `unverified` is NOT resolved: it may not even have been applied.
    var isResolved: Bool {
        switch self {
        case .archived, .restored, .deleted, .skipped:
            true
        case .failed, .unverified, .notAttempted:
            false
        }
    }

    /// Display-ready failure copy for the per-item detail list.
    var failureText: String? {
        if case .failed(let text) = self { return text }
        return nil
    }

    /// Display-ready reason for anything the user must see in the issue list
    /// (a failure, or an outcome that could not be verified).
    var issueText: String? {
        switch self {
        case .failed(let text), .unverified(let text): text
        default: nil
        }
    }
}

/// Cooperative cancellation for one batch. The executor checks it between
/// items only — an in-flight single-target command is never interrupted
/// halfway, so the store can never see a partially stopped task.
final class TaskBulkCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Bounded serial executor: one task at a time, in submission order.
struct TaskBulkRunner: Sendable {
    typealias Perform = @Sendable (TaskBulkItem) async -> TaskBulkItemOutcome

    /// Executes `items` one at a time. Duplicate identities are executed
    /// once. Identities in `excluding` were already resolved by an earlier
    /// run in the same management session and are never replayed (retry may
    /// only touch what still needs work). Cancellation is checked between
    /// items; remaining items are reported `.notAttempted` and stay
    /// actionable.
    func run(
        operation: TaskBulkOperation,
        items: [TaskBulkItem],
        excluding resolvedIDs: Set<UUID> = [],
        cancellation: TaskBulkCancellationToken? = nil,
        perform: Perform
    ) async -> TaskBulkSummary {
        var seen = Set<UUID>()
        var results: [TaskBulkItemResult] = []
        var wasCancelled = false
        for item in items {
            guard seen.insert(item.id).inserted else { continue }
            if resolvedIDs.contains(item.id) { continue }
            if wasCancelled || cancellation?.isCancelled == true {
                wasCancelled = true
                results.append(TaskBulkItemResult(item: item, outcome: .notAttempted))
                continue
            }
            let outcome = await perform(item)
            results.append(TaskBulkItemResult(item: item, outcome: outcome))
        }
        return TaskBulkSummary(operation: operation, results: results, wasCancelled: wasCancelled)
    }
}

/// Selection semantics for the management list. Select-all is scoped to what
/// the user can currently see (active filter + search); tasks hidden behind
/// another filter or a search are never swept in.
enum TaskBulkSelectionRules {
    static func toggled(_ selection: Set<UUID>, id: UUID) -> Set<UUID> {
        var next = selection
        if !next.insert(id).inserted { next.remove(id) }
        return next
    }

    /// Toggle: everything currently visible already selected -> deselect the
    /// visible subset; otherwise add exactly the visible subset.
    static func selectionAfterSelectAllToggle(_ selection: Set<UUID>, visible: Set<UUID>) -> Set<UUID> {
        guard !visible.isEmpty else { return selection }
        if visible.isSubset(of: selection) {
            return selection.subtracting(visible)
        }
        return selection.union(visible)
    }

    /// Keep only identities that are still visible (filter/search changes and
    /// disappearing rows must never leave an invisible pending selection).
    static func pruned(_ selection: Set<UUID>, to visible: Set<UUID>) -> Set<UUID> {
        selection.intersection(visible)
    }

    static func allVisibleSelected(_ selection: Set<UUID>, visible: Set<UUID>) -> Bool {
        !visible.isEmpty && visible.isSubset(of: selection)
    }
}
