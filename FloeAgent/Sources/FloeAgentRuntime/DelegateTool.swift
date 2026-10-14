// FloeAgentRuntime — delegate agent tool.
//
// Lets the parent run hand one subtask to a focused read-only subagent and
// receive a concise summary back. This is the Supervisor-Worker seam: the
// parent decides and aggregates; the subagent works in a clean context.

import Foundation
import Crypto
import FloeCore
import FloeTools

/// Delegates a subtask to a strictly read-only subagent and returns its summary.
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
        "Delegate one subtask to a focused, strictly read-only subagent that works in a clean context and returns a self-contained handoff summary. Types: `explore` (default; fast local workspace/conversation reads, no network) or `research` (adds read-only web/network evidence). It inherits the parent task's tool and workspace ceilings and cannot modify files, control GUIs, run code, or delegate again. Several independent delegate calls in one batch run in parallel — batch them. Give the subagent complete context: it sees nothing of this conversation beyond what you pass. The result is a structured receipt: `status=ok` means the subagent finished with a final answer; `status=partial` / `status=budgetExhausted` mean it ran out of iterations or shared budget and the findings are incomplete (treat them as non-success, not as a completed subtask); `status=cancelled`, `status=providerError` and `status=toolError` are failures. Each non-ok receipt lists bounded findings, evidence references and unfinished items."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "task": {"type": "string", "description": "The subtask for the subagent to complete"},
        "context": {"type": "string", "description": "Optional background the subagent needs"},
        "maxIterations": {"type": "integer", "description": "Maximum subagent turns (default 6, max 20)"},
        "type": {"type": "string", "enum": ["explore", "research"], "description": "explore = local reads only (default); research = adds read-only web/network tools"}
      },
      "required": ["task"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

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
        do {
            let outcome = try await runners.runSubagent(
                SubagentRequest(
                    task: args.task,
                    context: args.context,
                    maxIterations: args.maxIterations ?? 6,
                    kind: args.type ?? .explore,
                    runID: context.runID
                ),
                context: context
            )
            return Self.output(Self.render(outcome), exitStatus: Self.exitStatus(for: outcome.status))
        } catch {
            return Self.output("status=failed error=\(error.localizedDescription)", exitStatus: 1)
        }
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

/// Registers the delegate tool against the run-scoped runner registry.
@discardableResult
public func registerDelegateTool(
    registry: ToolRunnerRegistry = .shared,
    runners: SubagentRunnerRegistry
) -> SubagentRunnerRegistry {
    ToolCatalog.register(DelegateTool.self)
    registry.register(DelegateTool(runners: runners))
    return runners
}
