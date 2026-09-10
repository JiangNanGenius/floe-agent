import Foundation
import Crypto
import FloeCore
import FloeTools

public struct TaskReadPlanTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public init() {} }
    public static let name = "task.readPlan"
    public static let toolDescription = "Read this task's durable execution checklist and current revision. This progress record is not Goal-mode authorization; evidence references are model-supplied, not independent verification. Before resuming a large task, read this and continue unfinished steps without repeating completed side effects."
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    let store: TaskChecklistStore
    public init(store: TaskChecklistStore) { self.store = store }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        return try checklistOutput(await store.latest(runID: context.runID))
    }
}

public struct TaskUpdatePlanTool: AgentTool {
    public typealias Arguments = TaskChecklistUpdate
    public static let name = "task.updatePlan"
    public static let toolDescription = "For a substantial multi-step task, create a concise execution checklist before working and update it as evidence arrives. Simple questions need no checklist. Read task.readPlan first; send current expectedRevision (0 if absent), stable step IDs and at most one inProgress. Each successful update increments the revision by exactly 1, so after your own updates you already know the current revision without re-reading. If an update fails with 'Checklist changed: current revision is N', do NOT call task.readPlan again; immediately retry task.updatePlan once with expectedRevision=N and the same intended changes. When the user steers the running task or new evidence changes the approach, revise this same checklist: reorder or rename steps, append new steps, and reopen completed steps when their evidence is invalid. Preserve all existing IDs; cancel removed work explicitly. Do not use startNew to erase unfinished work. Completed steps need actual evidence references. startNew is only allowed after every previous step is completed or cancelled. Persists only Floe-owned progress; never starts Goal mode, grants authority, or declares the overall Goal complete."
    public static let parametersJSON = #"{"type":"object","properties":{"expectedRevision":{"type":"integer","minimum":0},"title":{"type":"string","maxLength":160},"startNew":{"type":"boolean"},"steps":{"type":"array","minItems":1,"maxItems":64,"items":{"type":"object","properties":{"id":{"type":"string","maxLength":80},"title":{"type":"string","maxLength":240},"status":{"type":"string","enum":["pending","inProgress","completed","blocked","cancelled"]},"evidence":{"type":"array","maxItems":4,"items":{"type":"string","maxLength":512}}},"required":["id","title","status","evidence"],"additionalProperties":false}}},"required":["expectedRevision","title","startNew","steps"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .internalState
    let store: TaskChecklistStore
    public init(store: TaskChecklistStore) { self.store = store }
    public func validate(_ args: Arguments) throws { try args.validate() }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let callID = context.toolCallID else { throw FloeError.validationFailed("Checklist update needs a durable tool call ID") }
        return try checklistOutput(await store.update(args, runID: context.runID, operationID: callID))
    }
}

private func checklistOutput(_ checklist: TaskChecklist?) throws -> ToolExecutionOutput {
    let data = try JSONEncoder().encode(checklist)
    return .init(summary: String(decoding: data, as: UTF8.self),
                 fullOutputSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                 maximumSummaryCharacters: 262_144)
}

public func registerTaskChecklistTools(store: TaskChecklistStore, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(TaskReadPlanTool.self)
    ToolCatalog.register(TaskUpdatePlanTool.self)
    registry.register(TaskReadPlanTool(store: store))
    registry.register(TaskUpdatePlanTool(store: store))
}
