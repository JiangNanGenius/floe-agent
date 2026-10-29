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

/// The canonical approval result behind this call's grant, issued by the
/// runtime at dispatch from the exact `ApprovalGrant` that authorized the
/// call. Never Codable and never model-minted. Consumers use it to know
/// whether the run's EFFECTIVE authority already covers an additional
/// in-call decision: a policy-authorized call (full-access, automatic,
/// approval-model, full-control) carries the user's standing policy choice,
/// while a one-off human inline card authorized exactly that call.
public enum ToolApprovalOrigin: Sendable, Hashable {
    /// A native inline ApprovalCard approved this exact call.
    case humanCard
    /// An existing approval policy authorized this call under its canonical
    /// policy name (`ApprovalPolicy.policyName`).
    case policy(String)
}

/// Result of a mid-execution (nested) human decision requested by an
/// executing tool through its `RuntimeNestedApprovalHandle`.
public enum NestedApprovalOutcome: Sendable, Equatable {
    /// The human allowed the exact requested action.
    case allowed
    /// The human denied it; the reason is the card's own denial text.
    case denied(reason: String)
    /// The run was cancelled (or the wait interrupted) while parked.
    case cancelled
    /// The canonical waiting surface was not available for this call (the
    /// run is not executing exactly this call, or no runtime seam exists in
    /// this context). Nothing was presented; callers must fail honestly.
    case unavailable
}

/// Runtime-issued handle letting ONE executing tool call request a canonical
/// human decision mid-execution. The runtime implementation moves the run
/// through the EXISTING `.waitingApproval` lifecycle — the same inline card,
/// the same `resolveApproval` entry, the same durable decision receipt, the
/// same liveness and background-ownership accounting — and the SAME tool
/// call then continues with the outcome. This is not a second approval
/// store: it re-enters the one canonical escalation path for a concrete
/// already-dispatched call. Never Codable and never model-minted.
public struct RuntimeNestedApprovalHandle: Sendable {
    private let escalate: @Sendable (String) async -> NestedApprovalOutcome

    public init(escalate: @escaping @Sendable (String) async -> NestedApprovalOutcome) {
        self.escalate = escalate
    }

    /// Requests the one human decision for this call. `reason` is the
    /// bounded user-visible description of EXACTLY what is being asked;
    /// native services build it from verified facts, never model text.
    public func request(reason: String) async -> NestedApprovalOutcome {
        await escalate(reason)
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
    /// Provider idempotency key of this exact approved call (may be empty).
    /// Runtime-issued authority binds it and consumers compare it.
    public var toolIdempotencyKey: String
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
    /// Exact professional-dataset accounts and registration generations frozen
    /// when this run started. This is native web.search authority, never a
    /// model-callable legacy alias or a live registry lookup. Children receive
    /// only the parent's value through the canonical dispatcher.
    public var professionalSearchAuthority: ProfessionalSearchAuthority.Frozen?
    /// True for temporary (ephemeral) chat runs: outbound web retrieval is
    /// public-only. Tools that can opt into LAN/diagnostic targets
    /// (web.fetch localNetwork) must refuse that opt-in and every private
    /// target here, regardless of ordinary policy. Set by the runtime from
    /// the run configuration; never model-minted.
    public var publicWebOnly: Bool
    /// Root assigned to this task. Workspace tools must prefer this over any
    /// UI-global workspace so concurrent tasks cannot leak into one another.
    public var workspaceRootURL: URL?
    /// Exact Canvas staged CAD document this run may touch through
    /// cad.document, or nil for runs without that verified binding. This is
    /// authority: it is seeded from the durable assistant binding at launch,
    /// never inferred from document text or model output.
    public var canvasStagedDocument: CanvasStagedDocumentAccess?
    /// Run-frozen native service identities supplied by the application, never model arguments.
    public var serviceStorePaths: [String: String]
    /// Optional workspace-relative file ceiling. An empty collection means
    /// the whole task workspace; entries authorize the path and descendants.
    public var allowedWorkspacePaths: [String]
    public var cancellation: CancellationToken
    /// Subagent budget handle when this tool runs as a delegated child.
    public var childBudget: ChildBudgetContext?
    /// Runtime-issued delegated-child handoff. Present on the `delegate`
    /// call context (the child about to run) and on every tool context a
    /// child executes, so the child knows its identity and can only reach
    /// tools through the parent's canonical dispatcher. Never Codable: a
    /// provider cannot mint an identity, a dispatcher or a peer handle.
    public var childExecution: ChildExecutionHandoff?
    /// Runtime-issued operation authority for this exact call. Minted by the
    /// runtime only after the canonical approval path already allowed the
    /// call; effectful tools that require trusted task authorization consume
    /// it at their own boundary. Never Codable and never model-minted.
    public var runtimeAuthority: RuntimeTaskAuthority?
    /// Runtime-issued provenance of this exact call. `delegate` and any other
    /// main-only capability check it at the callable boundary, so a wrapper
    /// context or a nested child can never smuggle a call that claims to
    /// originate from the main run. Never Codable and never model-minted.
    public var callOrigin: ToolCallOrigin?
    /// Progress reporter injected by the job executor while this tool runs
    /// inside a durable background job; nil in ordinary foreground runs.
    /// Read-only for tools: report only real processor units at natural
    /// checkpoints (coalescing/persistence belong to the injected reporter).
    public var taskProgress: (any TaskProgressReporting)?
    /// True when this run is a temporary (ephemeral) chat run. Set by the
    /// runtime from its immutable configuration; never model-minted. The
    /// runtime validates the temporary read-only policy before any effect;
    /// tools that hold their own resource ownership must treat every call in
    /// such a run as read-only public retrieval.
    public var temporaryReadOnly: Bool
    /// Runtime-issued stable identity of the CLIENT that owns this call inside
    /// one root task: the main run or one delegated child. Execution layers
    /// that own multi-client resources on a shared backend (guest console
    /// sessions, persistent PTYs, services) scope session ownership and
    /// cancellation to this identity, so sibling clients of the same task
    /// cannot exchange/close/signal each other's sessions. Never derived from
    /// model output and never Codable.
    public var clientSessionID: String?
    /// Frozen identity of the descriptors this run actually offers (plan-mode
    /// restriction, effective name ceiling, on-device curation, temporary
    /// read-only projection already applied). Permission/catalog identity is
    /// frozen separately from per-turn schemas: delegated children discover
    /// and dispatch against exactly this set, never a wider raw registry.
    /// `nil` preserves legacy contexts that predate the frozen identity.
    public var frozenEffectiveCatalogNames: Set<String>?
    /// Canonical approval result behind `approvalGrantID`, issued by the
    /// runtime at dispatch. `nil` for legacy contexts and unapproved calls;
    /// consumers treat `nil` conservatively (as the narrowest authority).
    public var approvalOrigin: ToolApprovalOrigin?
    /// Runtime-issued nested-approval seam for THIS exact executing call,
    /// present when the dispatching runtime can present the canonical
    /// mid-execution human decision. `nil` where no runtime surface exists
    /// (legacy contexts, detached jobs); a consumer that genuinely needs a
    /// human decision must then fail honestly instead of proceeding.
    public var nestedApproval: RuntimeNestedApprovalHandle?

    public init(
        runID: UUID,
        toolCallID: String? = nil,
        toolIdempotencyKey: String = "",
        approvalGrantID: UUID? = nil,
        scope: ToolScope = .local,
        activeSkillIDs: Set<String> = [],
        allowedToolNames: Set<String>? = nil,
        professionalSearchAuthority: ProfessionalSearchAuthority.Frozen? = nil,
        publicWebOnly: Bool = false,
        workspaceRootURL: URL? = nil,
        canvasStagedDocument: CanvasStagedDocumentAccess? = nil,
        serviceStorePaths: [String: String] = [:],
        allowedWorkspacePaths: [String] = [],
        cancellation: CancellationToken,
        childBudget: ChildBudgetContext? = nil,
        environmentID: String? = nil,
        conversationID: UUID? = nil,
        environment: ToolEnvironment? = nil,
        childExecution: ChildExecutionHandoff? = nil,
        runtimeAuthority: RuntimeTaskAuthority? = nil,
        callOrigin: ToolCallOrigin? = nil,
        taskProgress: (any TaskProgressReporting)? = nil,
        temporaryReadOnly: Bool = false,
        clientSessionID: String? = nil,
        frozenEffectiveCatalogNames: Set<String>? = nil,
        approvalOrigin: ToolApprovalOrigin? = nil,
        nestedApproval: RuntimeNestedApprovalHandle? = nil
    ) {
        self.runID = runID
        self.environmentID = environmentID
        self.conversationID = conversationID
        self.environment = environment
        self.toolCallID = toolCallID
        self.toolIdempotencyKey = toolIdempotencyKey
        self.approvalGrantID = approvalGrantID
        self.scope = scope
        self.activeSkillIDs = activeSkillIDs
        self.allowedToolNames = allowedToolNames
        self.professionalSearchAuthority = professionalSearchAuthority
        self.publicWebOnly = publicWebOnly
        self.workspaceRootURL = workspaceRootURL
        self.canvasStagedDocument = canvasStagedDocument
        self.serviceStorePaths = serviceStorePaths
        self.allowedWorkspacePaths = allowedWorkspacePaths
        self.cancellation = cancellation
        self.childBudget = childBudget
        self.childExecution = childExecution
        self.runtimeAuthority = runtimeAuthority
        self.callOrigin = callOrigin
        self.taskProgress = taskProgress
        self.temporaryReadOnly = temporaryReadOnly
        self.clientSessionID = clientSessionID
        self.frozenEffectiveCatalogNames = frozenEffectiveCatalogNames
        self.approvalOrigin = approvalOrigin
        self.nestedApproval = nestedApproval
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

    /// Bounded, printable session token that names THIS client's session on a
    /// shared backend: unique across the parent run and every sibling child of
    /// the same task even when two independent provider conversations happen
    /// to reuse the same tool-call identifier. Execution layers that already
    /// key per-exec sessions/commands by a token (the Linux guest console
    /// channel, shell sessions) use this instead of the bare provider call id,
    /// so a token collision can never route one client's output to another.
    /// The runtime seeds `clientSessionID`; the model cannot mint it, and if
    /// the combined value would exceed the printable token ceiling it is
    /// replaced by a bounded digest of itself.
    public var clientScopedSessionToken: String {
        let client = clientSessionID ?? "run:\(runID.uuidString)"
        let callID = toolCallID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = callID.isEmpty ? client : "\(client)-\(callID)"
        guard raw.utf8.count <= 96 else {
            return "sc-" + FloeDigest.sha256Hex(Data(raw.utf8)).prefix(40)
        }
        return raw
    }
}

/// Cooperative cancellation handle shared between the runtime and tools.
///
/// A token may derive child tokens (`derived()`): cancelling the parent
/// cancels every live descendant, while cancelling a child affects only that
/// child's own calls. This is how one delegated subagent can abort its own
/// in-flight work without stopping the parent run, its siblings or an
/// unrelated consumer of the same shared backend. Derivation is one-way
/// (parent → child); a child can never cancel its parent.
public final class CancellationToken: Sendable {
    private let storage: LockedBox

    /// Weak back-reference so a derived token that already went out of scope
    /// is not kept alive by its parent.
    private final class WeakToken: @unchecked Sendable {
        weak var token: CancellationToken?
        init(_ token: CancellationToken) { self.token = token }
    }

    private final class LockedBox: @unchecked Sendable {
        private var _cancelled = false
        private var derived: [WeakToken] = []
        private let lock = NSLock()

        var cancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _cancelled
        }

        /// Marks cancelled and returns the live descendants to propagate to.
        /// Returns an empty array when this token was already cancelled.
        func cancelAndCollectDescendants() -> [CancellationToken] {
            lock.lock()
            defer { lock.unlock() }
            guard !_cancelled else { return [] }
            _cancelled = true
            let tokens = derived.compactMap(\.token)
            derived.removeAll()
            return tokens
        }

        /// Registers `token` as a descendant. Returns false when this token is
        /// already cancelled, so the caller cancels the new token immediately
        /// instead of registering it behind an already-fired cancellation.
        func register(_ token: CancellationToken) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !_cancelled else { return false }
            derived.append(WeakToken(token))
            derived.removeAll { $0.token == nil }
            return true
        }
    }

    public init() {
        self.storage = LockedBox()
    }

    public var isCancelled: Bool { storage.cancelled }

    /// Cancels this token and every descendant derived from it. Cancelling an
    /// already-cancelled token is a no-op (never re-propagates).
    public func cancel() {
        for descendant in storage.cancelAndCollectDescendants() {
            descendant.cancel()
        }
    }

    /// Derives a child token that is cancelled when this token is cancelled,
    /// but can also be cancelled on its own without affecting this token or
    /// any sibling. If this token is already cancelled the returned token is
    /// cancelled before it is handed out, so no new work can slip past an
    /// inherited cancellation.
    public func derived() -> CancellationToken {
        let child = CancellationToken()
        guard storage.register(child) else {
            child.cancel()
            return child
        }
        if storage.cancelled { child.cancel() }
        return child
    }

    /// Throws `FloeError.cancelled` when cancellation has been requested.
    public func throwIfCancelled() throws {
        if isCancelled { throw FloeError.cancelled }
    }
}
