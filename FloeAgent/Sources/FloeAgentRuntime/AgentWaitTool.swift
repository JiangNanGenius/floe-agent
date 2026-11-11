import Foundation
import FloeCore
import FloeModels
import FloeTools

/// A real runtime suspension, not a scheduler or an early-success placeholder.
public struct AgentWaitTool: AgentTool {
    public static let name = "task.wait"
    public static let toolDescription = """
        Wait in this task for 0–86400 seconds OR until this task's existing native timer actually rings. Supply exactly one of seconds or alarmID. The tool stays pending until the condition is verified or guidance interrupts it. Stop cancels the wait; queued messages do not interrupt it. A recovered call waits only its saved remaining duration. A paused native timer stays paused; a missing/cancelled timer is not proof it rang. This does not create a scheduled task, grant device permission, or guarantee an exact background wake time. 在当前任务等待指定秒数或本任务已有原生计时器真正响铃；后台挂起时可能延迟继续。
        """
    public static let parametersJSON = #"{"type":"object","properties":{"seconds":{"type":"number","minimum":0,"maximum":86400,"description":"Seconds to wait in this call; mutually exclusive with alarmID. Zero completes immediately."},"alarmID":{"type":"string","format":"uuid","description":"Existing native timer owned by this task; mutually exclusive with seconds."}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .internalState
    public static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    public static let supportsConcurrentBatchDispatch = false
    public typealias Arguments = RuntimeWaitRequest

    public init() {}
    public func validate(_ args: Arguments) throws { try args.validate() }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try args.validate()
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly,
              context.childExecution == nil,
              context.conversationID != nil,
              let callID = context.toolCallID, !callID.isEmpty,
              let handle = context.runtimeWait else {
            throw AgentWaitError.unavailable
        }
        return try await handle.wait(args)
    }
}

public func registerAgentWaitTool(registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(AgentWaitTool.self)
    let tool = AnyAgentTool(AgentWaitTool())
    // A pure runtime suspension owns no workspace/backend resource. Keep the
    // canonical runtime approval and exact handle, without pinning a Linux
    // execution lease for the entire wait or opening any host fallback.
    registry.register(AnyAgentTool(descriptor: tool.descriptor, run: tool.run,
        validateArguments: tool.validateArguments, routing: ToolEnvironmentRouting()))
}
