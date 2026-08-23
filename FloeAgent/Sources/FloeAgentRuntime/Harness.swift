import Foundation
import FloeModels

public enum HarnessState: String, Sendable, Codable, Hashable {
    case idle
    case preparing
    case streaming
    case waitingApproval
    case waitingUser
    case executingTool
    case compacting
    case paused
    case interrupted
    case verifying
    case completed
    case cancelled
    case failed
}

public struct TextDelta: Sendable, Codable, Hashable {
    public var text: String
    public var blockID: String?

    public init(text: String, blockID: String? = nil) {
        self.text = text
        self.blockID = blockID
    }
}

public enum ToolLifecycleEvent: Sendable, Codable, Hashable {
    case requested(ToolCall)
    case started(ToolCall)
    case finished(ToolResult)
}

public struct ApprovalRequestSnapshot: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var toolCall: ToolCall
    public var reason: String
    public var requestedAt: Date

    public init(
        id: UUID = UUID(),
        toolCall: ToolCall,
        reason: String,
        requestedAt: Date = Date()
    ) {
        self.id = id
        self.toolCall = toolCall
        self.reason = reason
        self.requestedAt = requestedAt
    }
}

public struct ApprovalReviewSnapshot: Sendable, Codable, Hashable {
    public var toolName: String
    public var isEvaluating: Bool

    public init(toolName: String, isEvaluating: Bool) {
        self.toolName = toolName
        self.isEvaluating = isEvaluating
    }
}

public struct UsageSnapshot: Sendable, Codable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var modelCalls: Int
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var reasoningTokens: Int?
    public var totalDurationMs: Int?
    public var timeToFirstTokenMs: Int?
    public var tokensPerSecond: Double?
    public var costEstimate: Decimal?

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        modelCalls: Int = 0,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        totalDurationMs: Int? = nil,
        timeToFirstTokenMs: Int? = nil,
        tokensPerSecond: Double? = nil,
        costEstimate: Decimal? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.modelCalls = modelCalls
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.totalDurationMs = totalDurationMs
        self.timeToFirstTokenMs = timeToFirstTokenMs
        self.tokensPerSecond = tokensPerSecond
        self.costEstimate = costEstimate
    }
}

public struct ChildRunSnapshot: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var parentRunID: UUID
    public var taskSummary: String
    public var state: HarnessState
    public var iterationCount: Int

    public init(
        id: UUID,
        parentRunID: UUID,
        taskSummary: String,
        state: HarnessState,
        iterationCount: Int = 0
    ) {
        self.id = id
        self.parentRunID = parentRunID
        self.taskSummary = taskSummary
        self.state = state
        self.iterationCount = iterationCount
    }
}

public struct PlanSnapshot: Sendable, Codable, Hashable {
    public var id: UUID
    public var revision: Int
    public var status: PlanStatus

    public init(id: UUID, revision: Int, status: PlanStatus) {
        self.id = id
        self.revision = revision
        self.status = status
    }
}

public struct GoalSnapshot: Sendable, Codable, Hashable {
    public var id: UUID
    public var status: GoalStatus
    public var completedSteps: Int
    public var totalSteps: Int

    public init(id: UUID, status: GoalStatus, completedSteps: Int, totalSteps: Int) {
        self.id = id
        self.status = status
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
    }
}

public struct ContextCompactionRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var sourceMessageIDs: [UUID]
    public var sourceDigest: String
    public var beforeEstimatedTokens: Int
    public var afterEstimatedTokens: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        sourceMessageIDs: [UUID],
        sourceDigest: String,
        beforeEstimatedTokens: Int,
        afterEstimatedTokens: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceMessageIDs = sourceMessageIDs
        self.sourceDigest = sourceDigest
        self.beforeEstimatedTokens = beforeEstimatedTokens
        self.afterEstimatedTokens = afterEstimatedTokens
        self.createdAt = createdAt
    }
}

public enum HarnessTerminal: Sendable, Codable, Hashable {
    case completed
    case paused(reason: String)
    case interrupted(reason: String)
    case blocked(reason: String)
    case cancelled
    case failed(message: String, recoverable: Bool)
}

/// Push-only normalized event stream consumed by the UI and persistence
/// projection. It replaces polling snapshots without exposing provider wire
/// events to consumers.
public enum HarnessEvent: Sendable, Codable, Hashable {
    case stateChanged(HarnessState)
    case answerDelta(TextDelta)
    case reasoningDelta(TextDelta)
    case toolLifecycle(ToolLifecycleEvent)
    case approvalReviewChanged(ApprovalReviewSnapshot)
    case approvalRequested(ApprovalRequestSnapshot)
    case contextCompacted(ContextCompactionRecord)
    case planChanged(PlanSnapshot)
    case goalChanged(GoalSnapshot)
    case childRunChanged(ChildRunSnapshot)
    case userInputConsumed(SteerConsumptionReceipt)
    case usageChanged(UsageSnapshot)
    case terminal(HarnessTerminal)
}

/// Thread-safe multicast AsyncStream channel. Each subscriber gets a bounded
/// newest-value buffer so a background UI cannot grow memory without bound.
public final class HarnessEventChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<HarnessEvent>.Continuation] = [:]
    private var isFinished = false
    private let bufferLimit: Int

    public init(bufferLimit: Int = 512) {
        self.bufferLimit = max(1, bufferLimit)
    }

    public func stream() -> AsyncStream<HarnessEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(bufferLimit)) { continuation in
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.finish()
                return
            }
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    public func yield(_ event: HarnessEvent) {
        lock.lock()
        let active = Array(continuations.values)
        let finished = isFinished
        lock.unlock()
        guard !finished else { return }
        active.forEach { $0.yield(event) }
    }

    public func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let active = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        active.forEach { $0.finish() }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}

public struct HarnessBudgets: Sendable, Codable, Hashable {
    public var maxParentIterations: Int
    public var maxChildIterations: Int
    public var maxTotalIterations: Int
    public var maxConcurrentChildren: Int

    public init(
        maxParentIterations: Int = 90,
        maxChildIterations: Int = 50,
        maxTotalIterations: Int = 290,
        maxConcurrentChildren: Int = 4
    ) {
        self.maxParentIterations = max(1, maxParentIterations)
        self.maxChildIterations = max(1, maxChildIterations)
        self.maxTotalIterations = max(1, maxTotalIterations)
        self.maxConcurrentChildren = min(4, max(0, maxConcurrentChildren))
    }
}

public enum HarnessBudgetError: Error, Sendable, Codable, Hashable, LocalizedError {
    case parentIterationLimit
    case childIterationLimit(UUID)
    case totalIterationLimit
    case childConcurrencyLimit
    case unknownParent
    case unknownChild(UUID)
    case grandchildrenNotSupported

    public var errorDescription: String? {
        switch self {
        case .parentIterationLimit: "Parent iteration budget exhausted"
        case .childIterationLimit: "Child iteration budget exhausted"
        case .totalIterationLimit: "Activation iteration budget exhausted"
        case .childConcurrencyLimit: "Concurrent child run limit reached"
        case .unknownParent: "Child runs must be created by the root run"
        case .unknownChild: "Unknown child run"
        case .grandchildrenNotSupported: "Child runs cannot create grandchildren"
        }
    }
}

/// Actor owning the activation-wide budget. Reservation happens before a
/// model/tool iteration, so concurrency cannot oversubscribe the limit.
public actor HarnessBudgetLedger {
    public let rootRunID: UUID
    public let budgets: HarnessBudgets

    private var parentIterations = 0
    private var totalIterations = 0
    private var activeChildren: Set<UUID> = []
    private var childIterations: [UUID: Int] = [:]

    public init(rootRunID: UUID, budgets: HarnessBudgets = HarnessBudgets()) {
        self.rootRunID = rootRunID
        self.budgets = budgets
    }

    public func reserveParentIteration() throws {
        guard parentIterations < budgets.maxParentIterations else {
            throw HarnessBudgetError.parentIterationLimit
        }
        try reserveTotal()
        parentIterations += 1
    }

    public func startChild(id: UUID, requestedByRunID: UUID) throws {
        guard requestedByRunID == rootRunID else {
            if childIterations[requestedByRunID] != nil {
                throw HarnessBudgetError.grandchildrenNotSupported
            }
            throw HarnessBudgetError.unknownParent
        }
        guard activeChildren.count < budgets.maxConcurrentChildren else {
            throw HarnessBudgetError.childConcurrencyLimit
        }
        activeChildren.insert(id)
        childIterations[id] = 0
    }

    public func reserveChildIteration(id: UUID) throws {
        guard activeChildren.contains(id), let count = childIterations[id] else {
            throw HarnessBudgetError.unknownChild(id)
        }
        guard count < budgets.maxChildIterations else {
            throw HarnessBudgetError.childIterationLimit(id)
        }
        try reserveTotal()
        childIterations[id] = count + 1
    }

    public func finishChild(id: UUID) {
        activeChildren.remove(id)
    }

    public func snapshot() -> (parent: Int, total: Int, activeChildren: Int) {
        (parentIterations, totalIterations, activeChildren.count)
    }

    /// Restores durable counters before a resumed activation makes another
    /// provider call. Values are clamped so a malformed checkpoint cannot
    /// manufacture additional budget or move counters backwards.
    public func restore(parent: Int, total: Int) {
        parentIterations = min(budgets.maxParentIterations, max(parentIterations, parent))
        totalIterations = min(budgets.maxTotalIterations, max(totalIterations, total))
    }

    private func reserveTotal() throws {
        guard totalIterations < budgets.maxTotalIterations else {
            throw HarnessBudgetError.totalIterationLimit
        }
        totalIterations += 1
    }
}

/// Core harness coordination surface. Provider/tool orchestration can emit
/// into this object while UI and persistence independently subscribe.
public actor FloeHarness {
    public let runID: UUID
    public let conversationID: UUID
    public let mode: ConversationMode
    public let budgetLedger: HarnessBudgetLedger

    private nonisolated let eventChannel: HarnessEventChannel
    public private(set) var state: HarnessState = .idle

    public init(
        runID: UUID = UUID(),
        conversationID: UUID,
        mode: ConversationMode,
        budgets: HarnessBudgets = HarnessBudgets(),
        eventChannel: HarnessEventChannel = HarnessEventChannel()
    ) {
        self.runID = runID
        self.conversationID = conversationID
        self.mode = mode
        self.budgetLedger = HarnessBudgetLedger(rootRunID: runID, budgets: budgets)
        self.eventChannel = eventChannel
    }

    public nonisolated func events() -> AsyncStream<HarnessEvent> {
        eventChannel.stream()
    }

    public func transition(to state: HarnessState) {
        self.state = state
        eventChannel.yield(.stateChanged(state))
    }

    public func emit(_ event: HarnessEvent) {
        eventChannel.yield(event)
    }

    public func terminate(_ terminal: HarnessTerminal) {
        eventChannel.yield(.terminal(terminal))
        eventChannel.finish()
    }
}

/// Adapter allowing the existing single-run runtime to publish the Harness
/// push contract while migration to `FloeHarness` happens incrementally.
public final class AgentRuntimeHarnessBridge: AgentEventSink, @unchecked Sendable {
    private let channel: HarnessEventChannel

    public init(channel: HarnessEventChannel = HarnessEventChannel()) {
        self.channel = channel
    }

    public func events() -> AsyncStream<HarnessEvent> {
        channel.stream()
    }

    public func agentRuntime(_ runtime: FloeAgentRuntime, didTransitionTo state: AgentState) async {
        channel.yield(.stateChanged(Self.harnessState(for: state)))
        switch state {
        case .waitingApproval(let waiting):
            channel.yield(.approvalRequested(ApprovalRequestSnapshot(
                toolCall: waiting.toolCall,
                reason: waiting.reason,
                requestedAt: waiting.requestedAt
            )))
        case .completed:
            channel.yield(.terminal(.completed))
            channel.finish()
        case .failed(let failure):
            channel.yield(.terminal(.failed(
                message: failure.message,
                recoverable: failure.isRecoverable
            )))
            channel.finish()
        case .checkpointed:
            channel.yield(.terminal(.paused(reason: "checkpointed")))
        default:
            break
        }
    }

    public func agentRuntime(_ runtime: FloeAgentRuntime, didEmit event: AgentEvent) async {
        switch event {
        case .textDelta(let delta):
            channel.yield(.answerDelta(TextDelta(text: delta.text, blockID: delta.blockID)))
        case .reasoningSummary(let summary):
            channel.yield(.reasoningDelta(TextDelta(text: summary.text)))
        case .toolRequest(let call):
            channel.yield(.toolLifecycle(.requested(call)))
        case .toolResult(let result):
            channel.yield(.toolLifecycle(.finished(result)))
        case .usage(let usage):
            channel.yield(.usageChanged(UsageSnapshot(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                modelCalls: 0,
                cacheReadTokens: usage.cacheReadTokens,
                cacheWriteTokens: usage.cacheWriteTokens,
                reasoningTokens: usage.reasoningTokens,
                totalDurationMs: usage.totalDurationMs,
                timeToFirstTokenMs: usage.timeToFirstTokenMs,
                tokensPerSecond: usage.tokensPerSecond,
                costEstimate: usage.costEstimate
            )))
        case .error:
            break
        case .completed:
            break
        }
    }

    public func agentRuntime(
        _ runtime: FloeAgentRuntime,
        didChangeApprovalReview snapshot: ApprovalReviewSnapshot
    ) async {
        channel.yield(.approvalReviewChanged(snapshot))
    }

    private static func harnessState(for state: AgentState) -> HarnessState {
        switch state {
        case .idle: .idle
        case .preparing: .preparing
        case .streamingModel: .streaming
        case .waitingApproval: .waitingApproval
        case .executingTool: .executingTool
        case .compacting: .compacting
        case .verifying: .verifying
        case .checkpointed: .paused
        case .paused: .paused
        case .cancelling: .cancelled
        case .completed: .completed
        case .failed: .failed
        }
    }
}
