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
import FloePersistence
import FloeTools

/// Delegates one subtask to a focused subagent and returns its structured summary.
public struct DelegateTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var task: String
        public var context: String?
        public var maxIterations: Int?
        public var type: SubagentRequest.Kind?
        public var background: Bool?

        public init(task: String, context: String? = nil, maxIterations: Int? = nil, type: SubagentRequest.Kind? = nil, background: Bool? = nil) {
            self.task = task
            self.context = context
            self.maxIterations = maxIterations
            self.type = type
            self.background = background
        }
    }

    public static let name = "delegate"
    public static let toolDescription =
        "By default this call waits. Set background=true to continue independently, then use delegate.wait to check or wait for the child; account for its actual outcome before finishing. Delegate one subtask to a focused subagent that works in a clean context and returns a self-contained handoff summary. The subagent inherits this task's ACTUAL effective tools, workspace, environment and permissions — the same ceiling you hold, resolved per call by this task's own approval policy, so expect and honor approval prompts or denials. `type` is only a focus hint: `explore` (default; prefer fast local workspace/conversation reads), `research` (prefer web/network evidence) or `execute` (emphasize implementing/running the work end-to-end). No type grants extra rights or removes a right you hold. Children never modify their own permission ceiling and can never delegate further. Several independent delegate calls in one batch run in parallel — batch them; live sibling children may coordinate through delegate.peers/delegate.message. Give the subagent complete context: it sees nothing of this conversation beyond what you pass. The result is a structured receipt: `status=ok` means the subagent finished with a final answer; `status=partial` / `status=budgetExhausted` mean it ran out of iterations or shared budget and the findings are incomplete (treat them as non-success, not as a completed subtask); `status=cancelled`, `status=providerError` and `status=toolError` are failures. Each non-ok receipt lists bounded findings, evidence references and unfinished items."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "task": {"type": "string", "description": "The subtask for the subagent to complete"},
        "context": {"type": "string", "description": "Optional background the subagent needs"},
        "maxIterations": {"type": "integer", "description": "Maximum subagent turns (default 6, max 20)"},
        "type": {"type": "string", "enum": ["explore", "research", "execute"], "description": "Focus hint only; never changes permissions"},
        "background": {"type": "boolean", "description": "Start durably and return before completion; default false"}
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
        let request = SubagentRequest(task: args.task, context: args.context,
            maxIterations: args.maxIterations ?? 6, kind: args.type ?? .explore, runID: context.runID)
        if args.background == true {
            do {
                let id = try await runners.startBackground(request, context: context)
                if let conversationID = context.conversationID {
                    let child = try await runners.backgroundSnapshot(runID: context.runID, conversationID: conversationID, childID: id)
                    if child.state == .interrupted {
                        return Self.output("status=interrupted childID=\(id.uuidString); review or resume the child", exitStatus: 1)
                    }
                }
                return Self.output("status=started childID=\(id.uuidString); use delegate.wait for the actual outcome", exitStatus: 0)
            } catch {
                return Self.output("status=failed error=\(error.localizedDescription)", exitStatus: 1)
            }
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
                request,
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
    static func exitStatus(for status: SubagentOutcome.Status) -> Int32 {
        switch status {
        case .completed: 0
        default: 1
        }
    }

    static func render(_ outcome: SubagentOutcome) -> String {
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

    static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        return ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }
}

private actor BackgroundInterruptionFlag {
    private var interrupted = false
    func set() { interrupted = true }
    func get() -> Bool { interrupted }
}

public struct BackgroundChildSnapshot: Sendable {
    public let id: UUID
    public let state: ChildRunState
    public let outcome: SubagentOutcome?
    public let delivered: Bool
}

/// Run-scoped runner registry. A single process-global tool runner delegates
/// by parent run ID, so concurrent conversations never overwrite each
/// other's provider, model, credentials, or task ceiling.
public actor SubagentRunnerRegistry {
    private var runners: [UUID: SubagentRunner] = [:]
    private var backgroundTasks: [UUID: [UUID: Task<Void, Never>]] = [:]
    private var interruptionFlags: [UUID: [UUID: BackgroundInterruptionFlag]] = [:]
    private var starting: Set<String> = []
    private var closingRuns: Set<UUID> = []
    private var enabledBackgroundRuns: Set<UUID> = []

    public init() {}

    public func register(_ runner: SubagentRunner, for runID: UUID) {
        closingRuns.remove(runID)
        runners[runID] = runner
    }

    /// The owner calls this only after installing the full runtime lifecycle
    /// and persistence callbacks for this exact run.
    public func enableBackground(for runID: UUID) { enabledBackgroundRuns.insert(runID) }

    public func remove(runID: UUID) async {
        await cancelBackground(runID: runID)
        runners[runID] = nil
        enabledBackgroundRuns.remove(runID)
    }

    public func markBackgroundInterrupted(runID: UUID) async {
        closingRuns.insert(runID)
        for flag in interruptionFlags[runID, default: [:]].values { await flag.set() }
    }

    public func cancelBackground(runID: UUID) async {
        await markBackgroundInterrupted(runID: runID)
        let tasks = Array(backgroundTasks[runID, default: [:]].values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        backgroundTasks[runID] = nil
        interruptionFlags[runID] = nil
    }

    public func startBackground(_ request: SubagentRequest, context: ToolContext) async throws -> UUID {
        guard enabledBackgroundRuns.contains(context.runID), !closingRuns.contains(context.runID),
              request.runID == context.runID, let runner = runners[context.runID], let identity = context.childExecution?.identity,
              let conversationID = context.conversationID, let callID = context.toolCallID,
              identity.parentRunID == context.runID, identity.rootTaskID == conversationID,
              identity.delegateCallID == callID, identity.depth == 1 else {
            await context.childBudget?.finish()
            throw FloeError.invalidConfiguration("The background child has no authorized owner")
        }
        let key = "\(context.runID.uuidString):\(callID)"
        guard starting.insert(key).inserted else {
            await context.childBudget?.finish()
            throw FloeError.invalidConfiguration("This delegation is already starting")
        }
        defer { starting.remove(key) }
        // A replay of the same provider call MUST reuse the durable identity.
        do {
            let existing = try await runner.children(parentRunID: context.runID, conversationID: conversationID)
                .first(where: { $0.delegateCallID == callID })
            guard !closingRuns.contains(context.runID), !context.cancellation.isCancelled else {
                throw FloeError.invalidConfiguration("The parent task is stopping")
            }
            if let existing {
                // A crash can leave just the durable identity. Reuse it, but
                // never reclaim a child resumed by a different parent run.
                guard try await runner.backgroundChild(id: existing.id, parentRunID: context.runID, conversationID: conversationID) != nil else {
                    throw FloeError.validationFailed("The earlier background start was not completed; use a new delegation")
                }
                let transcript = try await runner.backgroundTranscript(childID: existing.id)
                if !transcript.startReady {
                    if !transcript.startFailed {
                        try await runner.recordBackgroundStartFailure(childID: existing.id, parentRunID: context.runID, conversationID: conversationID)
                    }
                    throw FloeError.validationFailed("The earlier background start did not execute; use a new delegation")
                }
                await context.childBudget?.finish()
                return existing.id
            }
            guard !closingRuns.contains(context.runID), !context.cancellation.isCancelled else {
                throw FloeError.invalidConfiguration("The parent task is stopping")
            }
        } catch {
            await context.childBudget?.finish()
            throw error
        }
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let interruptionFlag = BackgroundInterruptionFlag()
        interruptionFlags[context.runID, default: [:]][identity.childID] = interruptionFlag
        let task = Task {
            let peers = context.childExecution?.peers
            await peers?.register(String(request.task.prefix(120)))
            do {
                _ = try await runner.runStructured(request, context: context, onDurableRegistration: { value in
                    continuation.yield(value)
                    continuation.finish()
                }, isBackgroundInterrupted: { await interruptionFlag.get() })
            } catch {
                continuation.yield(false)
                continuation.finish()
            }
            await peers?.unregister()
        }
        backgroundTasks[context.runID, default: [:]][identity.childID] = task
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() == true else {
            await task.value
            backgroundTasks[context.runID]?[identity.childID] = nil
            interruptionFlags[context.runID]?[identity.childID] = nil
            throw FloeError.invalidConfiguration("The background child was not started because its durable record could not be created")
        }
        return identity.childID
    }

    public func isBackgroundChild(runID: UUID, conversationID: UUID, childID: UUID) async throws -> Bool {
        if backgroundTasks[runID]?[childID] != nil { return true }
        guard let runner = runners[runID] else { throw FloeError.invalidConfiguration("No runner is bound to this task") }
        return try await runner.isBackgroundChild(id: childID, conversationID: conversationID)
    }

    public func backgroundSnapshot(runID: UUID, conversationID: UUID, childID: UUID) async throws -> BackgroundChildSnapshot {
        guard let runner = runners[runID],
              let child = try await runner.backgroundChild(id: childID, parentRunID: runID, conversationID: conversationID) else {
            throw FloeError.validationFailed("No such child belongs to this task")
        }
        let transcript = try await runner.backgroundTranscript(childID: childID)
        guard transcript.isBackground, child.delegateCallID != nil else {
            throw FloeError.validationFailed("No such child belongs to this task")
        }
        if transcript.startFailed {
            let outcome = SubagentOutcome(status: .toolError, iterationsUsed: 0,
                findings: "The background child did not start. No provider or tool ran; review the startup failure before retrying.")
            return BackgroundChildSnapshot(id: childID, state: .toolError, outcome: outcome, delivered: transcript.delivered)
        }
        var outcome: SubagentOutcome?
        if let payload = transcript.resultJSON, let data = payload.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["status"] as? String, let status = SubagentOutcome.Status(rawValue: name) {
            outcome = SubagentOutcome(status: status,
                iterationsUsed: json["iterationsUsed"] as? Int ?? child.iterationCount,
                findings: json["findings"] as? String ?? "",
                evidence: json["evidence"] as? [String] ?? [],
                unfinished: json["unfinished"] as? [String] ?? [],
                truncated: json["truncated"] as? Bool ?? false)
        }
        // A result entry alone is not a committed terminal state. A crash
        // between append and finish must stay interrupted, never success.
        if !child.state.isTerminal || child.state == .interrupted { outcome = nil }
        if let result = outcome, result.status.rawValue != child.state.rawValue { outcome = nil }
        let state: ChildRunState = !child.state.isTerminal && backgroundTasks[runID]?[childID] == nil ? .interrupted : child.state
        return BackgroundChildSnapshot(id: childID, state: state, outcome: outcome, delivered: transcript.delivered)
    }

    public func settleBackground(runID: UUID, conversationID: UUID) async throws -> [BackgroundChildSnapshot] {
        guard let runner = runners[runID] else { throw FloeError.invalidConfiguration("No runner is bound to this task") }
        let tasks = Array(backgroundTasks[runID, default: [:]].values)
        for task in tasks { await task.value }
        let children = try await runner.backgroundChildren(parentRunID: runID, conversationID: conversationID)
        var snapshots: [BackgroundChildSnapshot] = []
        for child in children {
            let transcript = try await runner.backgroundTranscript(childID: child.id)
            if !transcript.startReady && !transcript.startFailed {
                // This also covers process death before the start boundary.
                // The store proves no execution and persists the failure.
                try await runner.recordBackgroundStartFailure(childID: child.id, parentRunID: runID, conversationID: conversationID)
            }
            let snapshot = try await backgroundSnapshot(runID: runID, conversationID: conversationID, childID: child.id)
            if !snapshot.delivered { snapshots.append(snapshot) }
        }
        return snapshots
    }

    public func markBackgroundDelivered(runID: UUID, conversationID: UUID, childIDs: [UUID]) async throws {
        guard let runner = runners[runID] else { throw FloeError.invalidConfiguration("No runner is bound to this task") }
        for id in childIDs {
            guard try await runner.backgroundChild(id: id, parentRunID: runID, conversationID: conversationID) != nil else {
                throw FloeError.validationFailed("The child does not belong to this task")
            }
            try await runner.markBackgroundDelivered(childID: id)
        }
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

public struct DelegateWaitTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let childID: UUID
        public let seconds: Double?
    }
    public static let name = "delegate.wait"
    public static let toolDescription = "Check or wait up to 30 seconds for one background child of this task. Set seconds=0 for a nonblocking status check. A running or interrupted child is not a completed result."
    public static let parametersJSON = #"{"type":"object","properties":{"childID":{"type":"string","format":"uuid"},"seconds":{"type":"number","minimum":0,"maximum":30}},"required":["childID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .internalState
    public static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    private let runners: SubagentRunnerRegistry
    public init(runners: SubagentRunnerRegistry) { self.runners = runners }
    public func validate(_ args: Arguments) throws {
        guard let seconds = args.seconds else { return }
        guard seconds.isFinite, (0...30).contains(seconds) else { throw FloeError.validationFailed("seconds must be between 0 and 30") }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        guard context.callOrigin?.authorizesMainOnlyCapability(toolName: Self.name, runID: context.runID, callID: context.toolCallID) == true,
              let conversationID = context.conversationID else {
            return DelegateTool.output("status=denied", exitStatus: 1)
        }
        let until = Date().addingTimeInterval(args.seconds ?? 0)
        while true {
            try context.cancellation.throwIfCancelled()
            try Task.checkCancellation()
            let child = try await runners.backgroundSnapshot(runID: context.runID, conversationID: conversationID, childID: args.childID)
            if let outcome = child.outcome {
                return DelegateTool.output(DelegateTool.render(outcome), exitStatus: DelegateTool.exitStatus(for: outcome.status))
            }
            if child.state.isTerminal {
                return DelegateTool.output("status=\(child.state.rawValue) childID=\(child.id.uuidString); result unavailable, review or resume the child", exitStatus: 1)
            }
            if Date() >= until { return DelegateTool.output("status=running childID=\(child.id.uuidString)", exitStatus: 0) }
            try await Task.sleep(for: .milliseconds(100))
        }
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
    ToolCatalog.register(DelegateWaitTool.self)
    registry.register(DelegateWaitTool(runners: runners))
    registerSubagentPeerTools(registry: registry)
    return runners
}
