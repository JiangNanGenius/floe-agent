import Foundation
import Crypto
import FloeCore
import FloeTools

public struct TaskReadPlanTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public init() {} }
    public static let name = "checklist.readPlan"
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
    public static let name = "checklist.updatePlan"
    public static let toolDescription = "For a substantial multi-step task, create a concise execution checklist before working and update it as evidence arrives. Simple questions need no checklist. Lifecycle: while a checklist has unfinished steps, each update must carry those step IDs (or mark them cancelled); completed/cancelled steps may be omitted — their history is preserved. When every step is completed or cancelled the checklist is FINISHED: your next updatePlan with a fresh steps array automatically starts a new checklist for the new task, so never append a new task's steps to a finished list. expectedRevision is optional: omit it to write over the current revision; provide it only if you are tracking revisions and want conflict detection. Each success returns the new revision, so do not call checklist.readPlan again after your own update. Use stable ASCII step IDs, at most one inProgress step, and evidence references for every completed step. startNew is rarely needed and rejected while unfinished steps remain. Validation errors name the exact steps to fix — correct and retry once. Only the main task round can write this checklist; a delegated subagent cannot replace it. Persists only Floe-owned progress; never starts Goal mode, grants authority, or declares the overall Goal complete."
    public static let parametersJSON = #"{"type":"object","properties":{"expectedRevision":{"type":"integer","minimum":0,"description":"Optional concurrency guard. Omit to write over the current revision."},"title":{"type":"string","maxLength":160},"startNew":{"type":"boolean","description":"Rarely needed: a finished checklist accepts a fresh steps array automatically. Rejected while unfinished steps remain."},"steps":{"type":"array","minItems":1,"maxItems":64,"items":{"type":"object","properties":{"id":{"type":"string","maxLength":80},"title":{"type":"string","maxLength":240},"status":{"type":"string","enum":["pending","inProgress","completed","blocked","cancelled"]},"evidence":{"type":"array","maxItems":4,"items":{"type":"string","maxLength":512}}},"required":["id","title","status","evidence"],"additionalProperties":false}}},"required":["title","steps"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .internalState
    /// Progress is owned by the main task round, exactly like reset: a
    /// delegated child's updatePlan must never replace the parent's visible
    /// title/steps/revisions. Children also have no need for a second
    /// checklist inside their bounded subtask, so the capability is excluded
    /// from their discovery universe and refused at the callable boundary.
    public static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    let store: TaskChecklistStore
    public init(store: TaskChecklistStore) { self.store = store }
    public func validate(_ args: Arguments) throws { try args.validate() }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly,
              context.childBudget == nil, context.childExecution == nil,
              context.conversationID != nil, let callID = context.toolCallID,
              context.callOrigin?.authorizesMainOnlyCapability(
                toolName: Self.name, runID: context.runID, callID: callID) == true else {
            throw FloeError.unauthorized
        }
        return try checklistOutput(await store.update(
            args, runID: context.runID, operationID: callID))
    }
}

public struct TaskResetPlanTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var expectedRevision: Int
        public init(expectedRevision: Int) { self.expectedRevision = expectedRevision }
    }
    public static let name = "checklist.resetPlan"
    public static let toolDescription = "Reset this task's current checklist at its observed expectedRevision, preserving every previous revision as history. Read checklist.readPlan first when the revision is unknown. Clears progress without claiming completion; never deletes chat, files, a proposal Plan or a Goal. A stale revision/run is refused. Replayed call identities return their original receipt without clearing later work. Then use checklist.updatePlan with a fresh steps array."
    public static let parametersJSON = #"{"type":"object","properties":{"expectedRevision":{"type":"integer","minimum":1}},"required":["expectedRevision"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .internalState
    /// Progress is owned by the main task round: a delegated child, a
    /// temporary/read-only run and any forged wrapper context must not clear
    /// the user's visible checklist.
    public static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    private let store: TaskChecklistStore
    public init(store: TaskChecklistStore) { self.store = store }
    public func validate(_ args: Arguments) throws {
        guard args.expectedRevision > 0 else {
            throw FloeError.validationFailed("expectedRevision must be at least 1")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args); try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly,
              context.childBudget == nil, context.childExecution == nil,
              let owner = context.conversationID, let call = context.toolCallID,
              context.callOrigin?.authorizesMainOnlyCapability(
                toolName: Self.name, runID: context.runID, callID: call) == true else {
            throw FloeError.unauthorized
        }
        let reset = try await store.reset(
            expectedRevision: args.expectedRevision,
            runID: context.runID,
            conversationID: owner,
            operationID: call)
        return try checklistOutput(reset)
    }
}

private func checklistOutput(_ checklist: TaskChecklist?) throws -> ToolExecutionOutput {
    let data = try JSONEncoder().encode(checklist)
    var summary = String(decoding: data, as: UTF8.self)
    // The lifecycle hint after the JSON payload is what prevents append-forever
    // checklists and pointless readPlan round-trips.
    if let checklist { summary += "\n" + checklist.lifecycleHint }
    return .init(summary: summary,
                 fullOutputSHA256: FloeDigest.sha256Hex(data),
                 maximumSummaryCharacters: 262_144)
}

public func registerTaskChecklistTools(store: TaskChecklistStore, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(TaskReadPlanTool.self)
    ToolCatalog.register(TaskUpdatePlanTool.self)
    ToolCatalog.register(TaskResetPlanTool.self)
    registry.register(TaskReadPlanTool(store: store))
    registry.register(TaskUpdatePlanTool(store: store))
    registry.register(TaskResetPlanTool(store: store))
}
