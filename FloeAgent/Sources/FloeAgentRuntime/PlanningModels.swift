import Foundation

/// The execution contract selected for a conversation turn.
public enum ConversationMode: String, Sendable, Codable, Hashable, CaseIterable {
    /// A normal single-turn conversation. Compiled tools may be available.
    case chat
    /// Read-only discovery that may persist only Floe-owned plan drafts.
    case plan
    /// A persistent, budgeted run that works toward evidence-backed criteria.
    case goal
}

public enum PlanStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case drafting
    case awaitingInput
    case ready
    case accepted
    case superseded
    case archived
}

public struct PlanSourceReference: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case message
        case conversation
        case file
        case web
        case artifact
    }

    public var id: UUID
    public var kind: Kind
    public var locator: String
    public var title: String?

    public init(id: UUID = UUID(), kind: Kind, locator: String, title: String? = nil) {
        self.id = id
        self.kind = kind
        self.locator = locator
        self.title = title
    }
}

public struct PlanSection: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var body: String
    public var order: Int
    public var sourceReferenceIDs: [UUID]

    public init(
        id: UUID = UUID(),
        title: String,
        body: String,
        order: Int,
        sourceReferenceIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.order = order
        self.sourceReferenceIDs = sourceReferenceIDs
    }
}

public struct PlanAssumption: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    public var isAccepted: Bool

    public init(id: UUID = UUID(), text: String, isAccepted: Bool = false) {
        self.id = id
        self.text = text
        self.isAccepted = isAccepted
    }
}

public struct PlanRisk: Sendable, Codable, Hashable, Identifiable {
    public enum Severity: String, Sendable, Codable, Hashable, Comparable {
        case low
        case medium
        case high

        public static func < (lhs: Self, rhs: Self) -> Bool {
            let order: [Self] = [.low, .medium, .high]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    public var id: UUID
    public var text: String
    public var mitigation: String?
    public var severity: Severity

    public init(
        id: UUID = UUID(),
        text: String,
        mitigation: String? = nil,
        severity: Severity = .medium
    ) {
        self.id = id
        self.text = text
        self.mitigation = mitigation
        self.severity = severity
    }
}

public struct PlanCriterion: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    public var verification: String

    public init(id: UUID = UUID(), text: String, verification: String) {
        self.id = id
        self.text = text
        self.verification = verification
    }
}

/// An immutable revision of a plan. Editing creates a new value with a
/// monotonically increasing revision and a digest supplied by persistence.
public struct PlanDraft: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var workspaceID: UUID?
    public var revision: Int
    public var status: PlanStatus
    public var title: String
    public var summary: String
    public var sections: [PlanSection]
    public var assumptions: [PlanAssumption]
    public var risks: [PlanRisk]
    public var acceptanceCriteria: [PlanCriterion]
    public var sourceMessageIDs: [UUID]
    public var sourceReferences: [PlanSourceReference]
    public var digest: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        workspaceID: UUID? = nil,
        revision: Int = 1,
        status: PlanStatus = .drafting,
        title: String,
        summary: String,
        sections: [PlanSection] = [],
        assumptions: [PlanAssumption] = [],
        risks: [PlanRisk] = [],
        acceptanceCriteria: [PlanCriterion] = [],
        sourceMessageIDs: [UUID] = [],
        sourceReferences: [PlanSourceReference] = [],
        digest: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        precondition(revision > 0, "Plan revisions start at one")
        self.id = id
        self.conversationID = conversationID
        self.workspaceID = workspaceID
        self.revision = revision
        self.status = status
        self.title = title
        self.summary = summary
        self.sections = sections
        self.assumptions = assumptions
        self.risks = risks
        self.acceptanceCriteria = acceptanceCriteria
        self.sourceMessageIDs = sourceMessageIDs
        self.sourceReferences = sourceReferences
        self.digest = digest
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var hasUnresolvedDecisions: Bool {
        status == .awaitingInput || assumptions.contains { !$0.isAccepted }
    }

    public var isDecisionComplete: Bool {
        status == .ready
            && !hasUnresolvedDecisions
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sections.isEmpty
            && !acceptanceCriteria.isEmpty
            && !acceptanceCriteria.contains {
                $0.verification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    /// Creates a new revision without mutating the source revision.
    public func revised(
        status: PlanStatus = .drafting,
        title: String? = nil,
        summary: String? = nil,
        sections: [PlanSection]? = nil,
        assumptions: [PlanAssumption]? = nil,
        risks: [PlanRisk]? = nil,
        acceptanceCriteria: [PlanCriterion]? = nil,
        sourceMessageIDs: [UUID]? = nil,
        sourceReferences: [PlanSourceReference]? = nil,
        digest: String = "",
        now: Date = Date()
    ) -> PlanDraft {
        PlanDraft(
            id: id,
            conversationID: conversationID,
            workspaceID: workspaceID,
            revision: revision + 1,
            status: status,
            title: title ?? self.title,
            summary: summary ?? self.summary,
            sections: sections ?? self.sections,
            assumptions: assumptions ?? self.assumptions,
            risks: risks ?? self.risks,
            acceptanceCriteria: acceptanceCriteria ?? self.acceptanceCriteria,
            sourceMessageIDs: sourceMessageIDs ?? self.sourceMessageIDs,
            sourceReferences: sourceReferences ?? self.sourceReferences,
            digest: digest,
            createdAt: createdAt,
            updatedAt: now
        )
    }
}

public struct PlanReadinessReview: Sendable, Codable, Hashable {
    public var missingDecisions: [String]
    public var missingEvidence: [String]
    public var reviewModelVerified: Bool

    public init(
        missingDecisions: [String] = [],
        missingEvidence: [String] = [],
        reviewModelVerified: Bool = false
    ) {
        self.missingDecisions = missingDecisions
        self.missingEvidence = missingEvidence
        self.reviewModelVerified = reviewModelVerified
    }

    public var isReady: Bool { missingDecisions.isEmpty && missingEvidence.isEmpty }
}

/// Deterministic portion of Plan-mode readiness. Model review is advisory:
/// if unavailable, the draft may still be ready but is marked unverified.
public enum PlanReadinessGate {
    public static func evaluate(
        _ draft: PlanDraft,
        referencedEnvironmentVerified: Bool,
        modelReview: PlanReadinessReview? = nil
    ) -> PlanReadinessReview {
        var decisions: [String] = []
        var evidence: [String] = []
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            decisions.append("title")
        }
        if draft.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            decisions.append("summary")
        }
        if draft.sections.isEmpty { decisions.append("implementation sections") }
        if draft.hasUnresolvedDecisions { decisions.append("unresolved assumptions or questions") }
        if draft.acceptanceCriteria.isEmpty { evidence.append("acceptance criteria") }
        if draft.acceptanceCriteria.contains(where: {
            $0.verification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            evidence.append("criterion verification")
        }
        if !referencedEnvironmentVerified { evidence.append("environment references") }
        if let modelReview {
            decisions.append(contentsOf: modelReview.missingDecisions)
            evidence.append(contentsOf: modelReview.missingEvidence)
        }
        return PlanReadinessReview(
            missingDecisions: Array(Set(decisions)).sorted(),
            missingEvidence: Array(Set(evidence)).sorted(),
            reviewModelVerified: modelReview?.reviewModelVerified ?? false
        )
    }
}

public enum GoalFromPlanFactory {
    public static func makeGoal(
        from plan: PlanDraft,
        budgets: GoalBudgets = GoalBudgets()
    ) throws -> ConversationGoal {
        guard plan.isDecisionComplete else {
            throw PlanConversionError.planNotDecisionComplete
        }
        let criteria = plan.acceptanceCriteria.map {
            GoalCriterion(text: $0.text)
        }
        let steps = plan.sections.sorted(by: { $0.order < $1.order }).enumerated().map { index, section in
            GoalStep(title: section.title, detail: section.body, order: index)
        }
        return ConversationGoal(
            conversationID: plan.conversationID,
            sourcePlanID: plan.id,
            sourcePlanDigest: plan.digest,
            objective: plan.summary,
            acceptanceCriteria: criteria,
            steps: steps,
            budgets: budgets
        )
    }
}

public enum PlanConversionError: Error, Sendable, Codable, Hashable {
    case planNotDecisionComplete
}
