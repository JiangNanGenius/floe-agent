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
    public static let toolDescription = "For a substantial multi-step task, create a concise execution checklist before working and update it as evidence arrives. Simple questions need no checklist. Lifecycle: while a checklist has unfinished steps, each update must carry those step IDs (or mark them cancelled); completed/cancelled steps may be omitted — their history is preserved. When every step is completed or cancelled the checklist is FINISHED: your next updatePlan with a fresh steps array automatically starts a new checklist for the new task, so never append a new task's steps to a finished list. expectedRevision is optional: omit it to write over the current revision; provide it only if you are tracking revisions and want conflict detection. Each success returns the new revision, so do not call task.readPlan again after your own update. Use stable ASCII step IDs, at most one inProgress step, and evidence references for every completed step. startNew is rarely needed and rejected while unfinished steps remain. Validation errors name the exact steps to fix — correct and retry once. Persists only Floe-owned progress; never starts Goal mode, grants authority, or declares the overall Goal complete."
    public static let parametersJSON = #"{"type":"object","properties":{"expectedRevision":{"type":"integer","minimum":0,"description":"Optional concurrency guard. Omit to write over the current revision."},"title":{"type":"string","maxLength":160},"startNew":{"type":"boolean","description":"Rarely needed: a finished checklist accepts a fresh steps array automatically. Rejected while unfinished steps remain."},"steps":{"type":"array","minItems":1,"maxItems":64,"items":{"type":"object","properties":{"id":{"type":"string","maxLength":80},"title":{"type":"string","maxLength":240},"status":{"type":"string","enum":["pending","inProgress","completed","blocked","cancelled"]},"evidence":{"type":"array","maxItems":4,"items":{"type":"string","maxLength":512}}},"required":["id","title","status","evidence"],"additionalProperties":false}}},"required":["title","steps"],"additionalProperties":false}"#
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
    var summary = String(decoding: data, as: UTF8.self)
    // The lifecycle hint after the JSON payload is what prevents append-forever
    // checklists and pointless readPlan round-trips.
    if let checklist { summary += "\n" + checklist.lifecycleHint }
    return .init(summary: summary,
                 fullOutputSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                 maximumSummaryCharacters: 262_144)
}

public func registerTaskChecklistTools(store: TaskChecklistStore, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(TaskReadPlanTool.self)
    ToolCatalog.register(TaskUpdatePlanTool.self)
    registry.register(TaskReadPlanTool(store: store))
    registry.register(TaskUpdatePlanTool(store: store))
}
