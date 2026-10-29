// FloeAgentRuntime — delegate agent tool.
//
// Lets the main run hand one subtask to a focused subagent and receive a
// concise, structured summary back. This is the Supervisor-Worker seam: the
// parent decides and aggregates; the subagent works in a clean context.
//
// Delegation is MAIN-RUN ONLY and is not read-only: with `type=execute` the
// child holds the parent's effective tool ceiling and every side-effecting
// child call is resolved by the parent runtime's canonical permission path
// (catalog, effective ceiling, catastrophic gate, approval policy and grants)
// before it executes. A child can never delegate further, and a denied call
// stays denied — the tool itself carries a conservative effect classification
// so it can never act as a silent read-only bypass.

import Foundation
import Crypto
import FloeCore
import FloeTools

/// Delegates one subtask to a focused subagent and returns its structured summary.
public struct DelegateTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var task: String
        public var context: String?
        public var maxIterations: Int?
        public var type: SubagentRequest.Kind?

        public init(task: String, context: String? = nil, maxIterations: Int? = nil, type: SubagentRequest.Kind? = nil) {
            self.task = task
            self.context = context
            self.maxIterations = maxIterations
            self.type = type
        }
    }

    public static let name = "delegate"
    public static let toolDescription =
        "Delegate one subtask to a focused subagent that works in a clean context and returns a self-contained handoff summary. The subagent inherits this task's ACTUAL effective tools, workspace, environment and permissions — the same ceiling you hold, resolved per call by this task's own approval policy, so expect and honor approval prompts or denials. `type` is only a focus hint: `explore` (default; prefer fast local workspace/conversation reads), `research` (prefer web/network evidence) or `execute` (emphasize implementing/running the work end-to-end). No type grants extra rights or removes a right you hold. Children never modify their own permission ceiling and can never delegate further. Several independent delegate calls in one batch run in parallel — batch them; live sibling children may coordinate through delegate.peers/delegate.message. Give the subagent complete context: it sees nothing of this conversation beyond what you pass. The result is a structured receipt: `status=ok` means the subagent finished with a final answer; `status=partial` / `status=budgetExhausted` mean it ran out of iterations or shared budget and the findings are incomplete (treat them as non-success, not as a completed subtask); `status=cancelled`, `status=providerError` and `status=toolError` are failures. Each non-ok receipt lists bounded findings, evidence references and unfinished items."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "task": {"type": "string", "description": "The subtask for the subagent to complete"},
        "context": {"type": "string", "description": "Optional background the subagent needs"},
        "maxIterations": {"type": "integer", "description": "Maximum subagent turns (default 6, max 20)"},
        "type": {"type": "string", "enum": ["explore", "research", "execute"], "description": "Focus hint only, never a permission change: explore = prefer fast local reads (default); research = prefer web/network evidence; execute = emphasize end-to-end execution. All types inherit the same effective parent ceiling with per-call approval"}
      },
      "required": ["task"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [
        .networkAccess, .readsFiles, .writesFiles, .deletesFiles, .executesLocalCode, .controlsGUI
    ]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    /// Delegation is main-run only: children cannot delegate, directly or
    /// through any wrapper, in discovery or at execution.
    public static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    /// The envelope's own effects are indirect and internally serialized by
    /// the child dispatcher (per-call approval + mutation leases), so two
    /// approved delegate calls in one batch may really run in parallel while
    /// direct writes remain batch barriers.
    public static let supportsConcurrentBatchDispatch = true

    static let maxTaskBytes = 32 * 1024

    private let runners: SubagentRunnerRegistry

    public init(runners: SubagentRunnerRegistry) {
        self.runners = runners
    }

    public func validate(_ args: Arguments) throws {
        let task = args.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { throw FloeError.validationFailed("task must not be empty") }
        guard task.utf8.count <= Self.maxTaskBytes else {
            throw FloeError.validationFailed("task exceeds \(Self.maxTaskBytes) bytes")
        }
        if let maxIterations = args.maxIterations,
           !(1...20).contains(maxIterations) {
            throw FloeError.validationFailed("maxIterations must be between 1 and 20")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        // Callable-boundary main-origin check: `delegate` may only run as the
        // main run's OWN approved call with this exact call id AND this exact
        // tool name. A delegated child — or a main-run wrapper/jobs/procedure
        // path that forwards its own identical context into this raw registry
        // entry — cannot delegate, because the origin is bound to the tool the
        // runtime actually approved. This is never a model-supplied flag, and
        // a missing origin is a refusal, never a main-run fallback.
        guard context.callOrigin?.authorizesMainOnlyCapability(
            toolName: Self.name,
            runID: context.runID,
            callID: context.toolCallID
        ) == true else {
            return Self.output(
                "status=denied reason=delegate may only run as the main run's own approved tool call; a delegated child or wrapper context cannot delegate",
                exitStatus: 1
            )
        }
        // The runtime seeds the child's identity/handoff on this call context.
        // Registering here (and unregistering on every exit path) gives the
        // child a real, bounded peer identity for its whole lifetime and
        // guarantees that no message can reach it after it finishes.
        let peers = context.childExecution?.peers
        await peers?.register(String(args.task.prefix(120)))
        let outcome: SubagentOutcome
        do {
            outcome = try await runners.runSubagent(
                SubagentRequest(
                    task: args.task,
                    context: args.context,
                    maxIterations: args.maxIterations ?? 6,
                    kind: args.type ?? .explore,
                    runID: context.runID
                ),
                context: context
            )
        } catch {
            await peers?.unregister()
            return Self.output("status=failed error=\(error.localizedDescription)", exitStatus: 1)
        }
        await peers?.unregister()
        return Self.output(Self.render(outcome), exitStatus: Self.exitStatus(for: outcome.status))
    }

    /// Partial/exhausted/cancelled/error terminations are NON-success: the
    /// parent model, the timeline and plan completion must read the real
    /// state instead of an "ok" wrapper around "no final answer".
    private static func exitStatus(for status: SubagentOutcome.Status) -> Int32 {
        switch status {
        case .completed: 0
        default: 1
        }
    }

    private static func render(_ outcome: SubagentOutcome) -> String {
        // Keep the historical provider-facing contract: a completed subagent
        // reads status=ok; every non-success state carries its structured
        // status name so the parent can tell partial/budget/cancel/error
        // apart instead of reading "ok" around "no final answer".
        let statusName = outcome.status == .completed
            ? "ok"
            : outcome.status.rawValue
        var text = "status=\(statusName) iterationsUsed=\(outcome.iterationsUsed)"
        if !outcome.unfinished.isEmpty {
            text += " unfinished=\(outcome.unfinished.count)"
        }
        if !outcome.evidence.isEmpty {
            text += "\nevidence: " + outcome.evidence.joined(separator: "; ")
        }
        if !outcome.unfinished.isEmpty {
            text += "\nunfinished: " + outcome.unfinished.joined(separator: "; ")
        }
        text += "\n\(outcome.findings)"
        return text
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        return ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }
}

/// Run-scoped runner registry. A single process-global tool runner delegates
/// by parent run ID, so concurrent conversations never overwrite each
/// other's provider, model, credentials, or task ceiling.
public actor SubagentRunnerRegistry {
    private var runners: [UUID: SubagentRunner] = [:]

    public init() {}

    public func register(_ runner: SubagentRunner, for runID: UUID) {
        runners[runID] = runner
    }

    public func remove(runID: UUID) {
        runners[runID] = nil
    }

    /// The runner bound to one live parent run. The durable child resume
    /// glue resolves the CURRENT run's runner through this getter, so a
    /// resumed child always executes under the actual authorized parent run
    /// that owns the runner — never an arbitrary or stale one.
    public func runner(for runID: UUID) -> SubagentRunner? {
        runners[runID]
    }

    /// Runs the structured subagent loop for one delegated subtask.
    public func runSubagent(
        _ request: SubagentRequest,
        context: ToolContext
    ) async throws -> SubagentOutcome {
        guard let runner = runners[context.runID] else {
            throw FloeError.invalidConfiguration("No subagent runner is bound to this run")
        }
        return try await runner.runStructured(request, context: context)
    }

    /// Legacy plain-summary entry point kept for existing callers; new callers
    /// should use `runSubagent` and read the structured termination status.
    public func run(_ request: SubagentRequest, context: ToolContext) async throws -> String {
        guard let runner = runners[context.runID] else {
            throw FloeError.invalidConfiguration("No subagent runner is bound to this run")
        }
        return try await runner.run(request, context: context)
    }
}

/// Registers the delegate tool plus the child-only sibling collaboration
/// tools against the run-scoped runner registry. One call site wires main-run
/// delegation and peer collaboration; the app needs no separate registration.
@discardableResult
public func registerDelegateTool(
    registry: ToolRunnerRegistry = .shared,
    runners: SubagentRunnerRegistry
) -> SubagentRunnerRegistry {
    ToolCatalog.register(DelegateTool.self)
    registry.register(DelegateTool(runners: runners))
    registerSubagentPeerTools(registry: registry)
    return runners
}
