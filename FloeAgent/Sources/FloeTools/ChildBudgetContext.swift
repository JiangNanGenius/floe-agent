// FloeTools — Child budget context for subagent delegation.
//
// When the parent runtime delegates a subtask, it opens a child slot in the
// shared HarnessBudgetLedger and hands this handle to the subagent. The
// subagent calls `reserve` before each iteration and `finish` exactly once
// at the end; the concrete ledger semantics stay behind the closures so
// FloeTools never depends on the runtime's ledger type.

import Foundation

/// Budget handle charged against the parent run's shared iteration ledger.
public struct ChildBudgetContext: Sendable {
    /// Maximum iterations this child may consume.
    public var maximumIterations: Int
    /// Reserves one child iteration. Returns false when the child or total
    /// budget is exhausted (the subagent must stop and summarize).
    public var reserve: @Sendable () async -> Bool
    /// Releases the child's concurrency slot. Must be called exactly once
    /// when the subagent finishes (or throws).
    public var finish: @Sendable () async -> Void

    public init(
        maximumIterations: Int,
        reserve: @escaping @Sendable () async -> Bool,
        finish: @escaping @Sendable () async -> Void
    ) {
        self.maximumIterations = max(1, maximumIterations)
        self.reserve = reserve
        self.finish = finish
    }
}
