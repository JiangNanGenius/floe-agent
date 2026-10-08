// FloeTools — Tool execution context.

import Foundation
import FloeCore
import FloeModels

/// Explicitly authorized Canvas staged CAD document for one run.
///
/// Seeded ONLY by the launch path that verified the durable Drawing
/// Assistant binding (review sheet → conversation → binding store). The
/// cad.document tool derives its `CadDocumentAccess` from this value, never
/// from prompt/drawing text: a model quoting a path gains no authority.
/// The staged bytes are the editable draft; the canvas node changes only
/// when the user explicitly Finishes, so assistant proposals stay draft.
public struct CanvasStagedDocumentAccess: Sendable, Hashable {
    /// Canvas project that owns the staged draft.
    public var canvasID: UUID
    /// App-owned canvas draft root (the CAD workspace root).
    public var draftRootPath: String
    /// The exact staged document, relative to the draft root.
    public var stagedRelativePath: String

    public init(canvasID: UUID, draftRootPath: String, stagedRelativePath: String) {
        self.canvasID = canvasID
        self.draftRootPath = draftRootPath
        self.stagedRelativePath = stagedRelativePath
    }
}

/// Per-execution context handed to every tool.
public struct ToolContext: Sendable {
    public var runID: UUID    /// Container/environment the run executes in. Tools that install or
    /// execute packages (exec.shell, apt, pip, npm) resolve their writable
    /// layer from this identifier; nil means the default project container.
    public var environmentID: String?
    public var conversationID: UUID?
    public var environment: ToolEnvironment?
    /// Durable provider call identifier. Remote/durable tools use it as an
    /// idempotency key so reconnecting never starts the same action twice.
    public var toolCallID: String?
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
    /// Root assigned to this task. Workspace tools must prefer this over any
    /// UI-global workspace so concurrent tasks cannot leak into one another.
    public var workspaceRootURL: URL?
    /// Exact Canvas staged CAD document this run may touch through
    /// cad.document, or nil for runs without that verified binding. This is
    /// authority: it is seeded from the durable assistant binding at launch,
    /// never inferred from document text or model output.
    public var canvasStagedDocument: CanvasStagedDocumentAccess?
    /// Optional workspace-relative file ceiling. An empty collection means
    /// the whole task workspace; entries authorize the path and descendants.
    public var allowedWorkspacePaths: [String]
    public var cancellation: CancellationToken
    /// Subagent budget handle when this tool runs as a delegated child.
    public var childBudget: ChildBudgetContext?

    public init(
        runID: UUID,
        toolCallID: String? = nil,
        approvalGrantID: UUID? = nil,
        scope: ToolScope = .local,
        activeSkillIDs: Set<String> = [],
        allowedToolNames: Set<String>? = nil,
        workspaceRootURL: URL? = nil,
        canvasStagedDocument: CanvasStagedDocumentAccess? = nil,
        allowedWorkspacePaths: [String] = [],
        cancellation: CancellationToken,
        childBudget: ChildBudgetContext? = nil,
        environmentID: String? = nil,
        conversationID: UUID? = nil,
        environment: ToolEnvironment? = nil
    ) {
        self.runID = runID
        self.environmentID = environmentID
        self.conversationID = conversationID
        self.environment = environment
        self.toolCallID = toolCallID
        self.approvalGrantID = approvalGrantID
        self.scope = scope
        self.activeSkillIDs = activeSkillIDs
        self.allowedToolNames = allowedToolNames
        self.workspaceRootURL = workspaceRootURL
        self.canvasStagedDocument = canvasStagedDocument
        self.allowedWorkspacePaths = allowedWorkspacePaths
        self.cancellation = cancellation
        self.childBudget = childBudget
    }

    /// Enforces the task's persisted file scope before the workspace path
    /// guard resolves the path against the root. This is intentionally a
    /// second boundary: the path guard still prevents traversal/symlinks.
    public func authorizeWorkspacePath(_ path: String) throws {
        guard !allowedWorkspacePaths.isEmpty else { return }
        let candidate = Self.normalizedRelativePath(path)
        let allowed = allowedWorkspacePaths.contains { declared in
            let ceiling = Self.normalizedRelativePath(declared)
            return ceiling == "." || candidate == ceiling || candidate.hasPrefix(ceiling + "/")
        }
        guard allowed else {
            throw FloeError.validationFailed("Task file scope does not permit \(path)")
        }
    }

    private static func normalizedRelativePath(_ path: String) -> String {
        var pieces: [Substring] = []
        for component in path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !pieces.isEmpty { pieces.removeLast() }
            default:
                pieces.append(component)
            }
        }
        return pieces.isEmpty ? "." : pieces.joined(separator: "/")
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
