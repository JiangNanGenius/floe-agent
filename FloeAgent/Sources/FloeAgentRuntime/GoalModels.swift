import Foundation

public enum GoalStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case draft
    case active
    case waitingApproval
    case waitingUser
    case paused
    case interrupted
    case blocked
    case budgetLimited
    case verifying
    case completed
    case cancelled
    case failed

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed: true
        default: false
        }
    }
}

public enum GoalStepStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case pending
    case inProgress
    case completed
    case failed
    case skipped
}

public struct GoalEvidence: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case testResult
        case file
        case screenshot
        case toolResult
        case artifact
        case userConfirmation
    }

    public var id: UUID
    public var kind: Kind
    public var reference: String
    public var summary: String
    public var capturedAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        reference: String,
        summary: String,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.reference = reference
        self.summary = summary
        self.capturedAt = capturedAt
    }
}

public struct GoalCriterion: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    public var isSatisfied: Bool
    public var evidenceIDs: [UUID]
    public var requiresUserConfirmation: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        isSatisfied: Bool = false,
        evidenceIDs: [UUID] = [],
        requiresUserConfirmation: Bool = false
    ) {
        self.id = id
        self.text = text
        self.isSatisfied = isSatisfied
        self.evidenceIDs = evidenceIDs
        self.requiresUserConfirmation = requiresUserConfirmation
    }
}

public struct GoalStep: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var status: GoalStepStatus
    public var order: Int
    public var evidenceIDs: [UUID]

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String = "",
        status: GoalStepStatus = .pending,
        order: Int,
        evidenceIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.order = order
        self.evidenceIDs = evidenceIDs
    }
}

public struct GoalBudgets: Sendable, Codable, Hashable {
    public var maxCycles: Int?
    public var maxModelCalls: Int?
    public var maxWallClockSeconds: TimeInterval?
    public var maxParentIterationsPerCycle: Int
    public var maxChildIterations: Int
    public var maxTotalIterationsPerActivation: Int
    public var maxConcurrentChildren: Int
    public var costReminder: Decimal?

    public init(
        maxCycles: Int? = nil,
        maxModelCalls: Int? = nil,
        maxWallClockSeconds: TimeInterval? = nil,
        maxParentIterationsPerCycle: Int = 64,
        maxChildIterations: Int = 24,
        maxTotalIterationsPerActivation: Int = 96,
        maxConcurrentChildren: Int = 3,
        costReminder: Decimal? = nil
    ) {
        self.maxCycles = maxCycles.map { max(1, $0) }
        self.maxModelCalls = maxModelCalls.map { max(1, $0) }
        self.maxWallClockSeconds = maxWallClockSeconds.map { max(1, $0) }
        self.maxParentIterationsPerCycle = max(1, maxParentIterationsPerCycle)
        self.maxChildIterations = max(1, maxChildIterations)
        self.maxTotalIterationsPerActivation = max(1, maxTotalIterationsPerActivation)
        self.maxConcurrentChildren = min(3, max(0, maxConcurrentChildren))
        self.costReminder = costReminder
    }
}

public struct GoalProgress: Sendable, Codable, Hashable {
    public var cycleCount: Int
    public var modelCallCount: Int
    public var totalIterationCount: Int
    public var startedAt: Date?
    public var lastCheckpointAt: Date?
    public var repeatedBlockerKey: String?
    public var repeatedBlockerCount: Int

    public init(
        cycleCount: Int = 0,
        modelCallCount: Int = 0,
        totalIterationCount: Int = 0,
        startedAt: Date? = nil,
        lastCheckpointAt: Date? = nil,
        repeatedBlockerKey: String? = nil,
        repeatedBlockerCount: Int = 0
    ) {
        self.cycleCount = cycleCount
        self.modelCallCount = modelCallCount
        self.totalIterationCount = totalIterationCount
        self.startedAt = startedAt
        self.lastCheckpointAt = lastCheckpointAt
        self.repeatedBlockerKey = repeatedBlockerKey
        self.repeatedBlockerCount = repeatedBlockerCount
    }
}

public struct ConversationGoal: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var sourcePlanID: UUID?
    public var sourcePlanDigest: String?
    public var objective: String
    /// Explicit user-defined conditions that stop further action and surface
    /// the Goal as blocked instead of encouraging improvisation.
    public var blockingConditions: [String]?
    /// User-defined successful stopping conditions, separate from budgets.
    public var stoppingConditions: [String]?
    /// Monotonic revision for user edits; nil decodes legacy rows as v1.
    public var revision: Int?
    public var acceptanceCriteria: [GoalCriterion]
    public var steps: [GoalStep]
    public var evidence: [GoalEvidence]
    public var status: GoalStatus
    public var budgets: GoalBudgets
    public var progress: GoalProgress
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        sourcePlanID: UUID? = nil,
        sourcePlanDigest: String? = nil,
        objective: String,
        blockingConditions: [String]? = nil,
        stoppingConditions: [String]? = nil,
        revision: Int? = 1,
        acceptanceCriteria: [GoalCriterion],
        steps: [GoalStep],
        evidence: [GoalEvidence] = [],
        status: GoalStatus = .draft,
        budgets: GoalBudgets = GoalBudgets(),
        progress: GoalProgress = GoalProgress(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.sourcePlanID = sourcePlanID
        self.sourcePlanDigest = sourcePlanDigest
        self.objective = objective
        self.blockingConditions = blockingConditions
        self.stoppingConditions = stoppingConditions
        self.revision = revision
        self.acceptanceCriteria = acceptanceCriteria
        self.steps = steps
        self.evidence = evidence
        self.status = status
        self.budgets = budgets
        self.progress = progress
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func recordBlocker(key: String) {
        if progress.repeatedBlockerKey == key {
            progress.repeatedBlockerCount += 1
        } else {
            progress.repeatedBlockerKey = key
            progress.repeatedBlockerCount = 1
        }
        if progress.repeatedBlockerCount >= 3 {
            status = .blocked
        }
        updatedAt = Date()
    }
}

public struct GoalCompletionProposal: Sendable, Codable, Hashable {
    public var goalID: UUID
    public var criterionEvidence: [UUID: [UUID]]
    public var reviewModelApproved: Bool
    public var failedCheckReferences: [String]
    public var unresolvedErrorReferences: [String]

    public init(
        goalID: UUID,
        criterionEvidence: [UUID: [UUID]],
        reviewModelApproved: Bool,
        failedCheckReferences: [String] = [],
        unresolvedErrorReferences: [String] = []
    ) {
        self.goalID = goalID
        self.criterionEvidence = criterionEvidence
        self.reviewModelApproved = reviewModelApproved
        self.failedCheckReferences = failedCheckReferences
        self.unresolvedErrorReferences = unresolvedErrorReferences
    }
}

public enum GoalCompletionBlocker: Sendable, Codable, Hashable {
    case wrongGoal
    case goalAlreadyTerminal
    case incompleteStep(UUID)
    case unsatisfiedCriterion(UUID)
    case missingEvidence(UUID)
    case unknownEvidence(UUID)
    case userConfirmationRequired(UUID)
    case reviewRejected
    case failedChecks([String])
    case unresolvedErrors([String])
}

public struct GoalCompletionVerdict: Sendable, Codable, Hashable {
    public var mayComplete: Bool
    public var blockers: [GoalCompletionBlocker]

    public init(mayComplete: Bool, blockers: [GoalCompletionBlocker]) {
        self.mayComplete = mayComplete
        self.blockers = blockers
    }
}

/// Local fail-closed gate. A model's completion claim is never sufficient.
public enum GoalCompletionGate {
    public static func evaluate(
        goal: ConversationGoal,
        proposal: GoalCompletionProposal,
        userConfirmedCriterionIDs: Set<UUID> = []
    ) -> GoalCompletionVerdict {
        var blockers: [GoalCompletionBlocker] = []
        guard proposal.goalID == goal.id else {
            return GoalCompletionVerdict(mayComplete: false, blockers: [.wrongGoal])
        }
        if goal.status.isTerminal { blockers.append(.goalAlreadyTerminal) }
        for step in goal.steps where step.status != .completed && step.status != .skipped {
            blockers.append(.incompleteStep(step.id))
        }
        let knownEvidence = Set(goal.evidence.map(\.id))
        for criterion in goal.acceptanceCriteria {
            guard criterion.isSatisfied else {
                blockers.append(.unsatisfiedCriterion(criterion.id))
                continue
            }
            let supplied = proposal.criterionEvidence[criterion.id, default: []]
            if supplied.isEmpty { blockers.append(.missingEvidence(criterion.id)) }
            if !Set(supplied).isSubset(of: knownEvidence) {
                blockers.append(.unknownEvidence(criterion.id))
            }
            if criterion.requiresUserConfirmation && !userConfirmedCriterionIDs.contains(criterion.id) {
                blockers.append(.userConfirmationRequired(criterion.id))
            }
        }
        if !proposal.reviewModelApproved { blockers.append(.reviewRejected) }
        if !proposal.failedCheckReferences.isEmpty {
            blockers.append(.failedChecks(proposal.failedCheckReferences))
        }
        if !proposal.unresolvedErrorReferences.isEmpty {
            blockers.append(.unresolvedErrors(proposal.unresolvedErrorReferences))
        }
        return GoalCompletionVerdict(mayComplete: blockers.isEmpty, blockers: blockers)
    }
}
