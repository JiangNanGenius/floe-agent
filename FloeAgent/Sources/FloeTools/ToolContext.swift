// FloeTools — Tool execution context.

import Foundation
import FloeCore
import FloeModels

/// Per-execution context handed to every tool.
public struct ToolContext: Sendable {
    public var runID: UUID
    /// Approval grant under which this execution proceeds. `nil` only for
    /// non-side-effecting tools.
    public var approvalGrantID: UUID?
    /// Canonical scope from the approved `ToolCall`. Tools must authorize
    /// against this value instead of re-inferring authority from JSON.
    public var scope: ToolScope
    /// Skills active for this run. This is provenance, not authority.
    public var activeSkillIDs: Set<String>
    /// Executor-side capability ceiling derived before the provider request.
    public var allowedToolNames: Set<String>?
    public var cancellation: CancellationToken

    public init(
        runID: UUID,
        approvalGrantID: UUID? = nil,
        scope: ToolScope = .local,
        activeSkillIDs: Set<String> = [],
        allowedToolNames: Set<String>? = nil,
        cancellation: CancellationToken
    ) {
        self.runID = runID
        self.approvalGrantID = approvalGrantID
        self.scope = scope
        self.activeSkillIDs = activeSkillIDs
        self.allowedToolNames = allowedToolNames
        self.cancellation = cancellation
    }
}

/// Cooperative cancellation handle shared between the runtime and tools.
public final class CancellationToken: Sendable {
    private let storage: LockedBox

    private final class LockedBox: @unchecked Sendable {
        private var _cancelled = false
        private let lock = NSLock()

        var cancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _cancelled
        }

        func cancel() {
            lock.lock()
            _cancelled = true
            lock.unlock()
        }
    }

    public init() {
        self.storage = LockedBox()
    }

    public var isCancelled: Bool { storage.cancelled }
    public func cancel() { storage.cancel() }

    /// Throws `FloeError.cancelled` when cancellation has been requested.
    public func throwIfCancelled() throws {
        if isCancelled { throw FloeError.cancelled }
    }
}
