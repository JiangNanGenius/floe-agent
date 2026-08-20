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

        public init(task: String, context: String? = nil, maxIterations: Int? = nil) {
            self.task = task
            self.context = context
            self.maxIterations = maxIterations
        }
    }

    public static let name = "delegate"
    public static let toolDescription =
        "Delegate one subtask to a focused, strictly read-only subagent that works in a clean context and returns a concise summary. It inherits the parent task's tool and workspace ceilings and cannot modify files, control GUIs, run code, or delegate again."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "task": {"type": "string", "description": "The subtask for the subagent to complete"},
        "context": {"type": "string", "description": "Optional background the subagent needs"},
        "maxIterations": {"type": "integer", "description": "Maximum subagent turns (default 6, max 20)"}
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
            let summary = try await runners.run(
                SubagentRequest(
                    task: args.task,
                    context: args.context,
                    maxIterations: args.maxIterations ?? 6,
                    runID: context.runID
                ),
                context: context
            )
            return Self.output("status=ok\n\(summary)", exitStatus: 0)
        } catch {
            return Self.output("status=failed error=\(error.localizedDescription)", exitStatus: 1)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
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
