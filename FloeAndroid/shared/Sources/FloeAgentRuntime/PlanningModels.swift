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

/// The model's recommendation is advisory and visible before acceptance. A
/// user may always force ordinary execution or durable Goal execution.
public enum PlanExecutionRecommendation: String, Sendable, Codable, Hashable, CaseIterable {
    case normal
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
    public var executionRecommendation: PlanExecutionRecommendation?
    public var recommendationReason: String?
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
        executionRecommendation: PlanExecutionRecommendation? = .normal,
        recommendationReason: String? = nil,
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
        self.executionRecommendation = executionRecommendation
        self.recommendationReason = recommendationReason
        self.digest = digest
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var hasUnresolvedDecisions: Bool {
        status == .awaitingInput || assumptions.contains { !$0.isAccepted }
    }

    public var isDecisionComplete: Bool {
        (status == .ready || status == .accepted)
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
        executionRecommendation: PlanExecutionRecommendation? = nil,
        recommendationReason: String? = nil,
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
            executionRecommendation: executionRecommendation ?? self.executionRecommendation,
            recommendationReason: recommendationReason ?? self.recommendationReason,
            digest: digest,
            createdAt: createdAt,
            updatedAt: now
        )
    }
}

/// Strict payload for the internal `plan.submit` native tool. Unlike parsing
/// display Markdown, every field needed by the review/acceptance UI is typed.
public struct PlanSubmission: Sendable, Codable, Hashable {
    public struct Section: Sendable, Codable, Hashable {
        public var title: String
        public var body: String
        public init(title: String, body: String) { self.title = title; self.body = body }
    }

    public struct Risk: Sendable, Codable, Hashable {
        public var text: String
        public var mitigation: String
        public var severity: PlanRisk.Severity
        public init(text: String, mitigation: String, severity: PlanRisk.Severity) {
            self.text = text; self.mitigation = mitigation; self.severity = severity
        }
    }

    public struct Criterion: Sendable, Codable, Hashable {
        public var text: String
        public var verification: String
        public init(text: String, verification: String) {
            self.text = text; self.verification = verification
        }
    }

    public var title: String
    public var summary: String
    public var sections: [Section]
    public var assumptions: [String]
    public var risks: [Risk]
    public var acceptanceCriteria: [Criterion]
    public var executionRecommendation: PlanExecutionRecommendation
    public var recommendationReason: String

    public init(
        title: String,
        summary: String,
        sections: [Section],
        assumptions: [String] = [],
        risks: [Risk] = [],
        acceptanceCriteria: [Criterion],
        executionRecommendation: PlanExecutionRecommendation = .normal,
        recommendationReason: String = ""
    ) {
        self.title = title
        self.summary = summary
        self.sections = sections
        self.assumptions = assumptions
        self.risks = risks
        self.acceptanceCriteria = acceptanceCriteria
        self.executionRecommendation = executionRecommendation
        self.recommendationReason = recommendationReason
    }

    public var validationErrors: [String] {
        var errors: [String] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("title") }
        if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("summary") }
        if sections.isEmpty { errors.append("sections") }
        if sections.contains(where: { $0.title.isEmpty || $0.body.isEmpty }) { errors.append("section content") }
        if acceptanceCriteria.isEmpty { errors.append("acceptanceCriteria") }
        if acceptanceCriteria.contains(where: { $0.text.isEmpty || $0.verification.isEmpty }) {
            errors.append("criterion verification")
        }
        if executionRecommendation == .goal && recommendationReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Goal recommendation reason")
        }
        return errors
    }

    public func draft(conversationID: UUID, prior: PlanDraft? = nil) -> PlanDraft {
        let mappedSections = sections.enumerated().map {
            PlanSection(title: $0.element.title, body: $0.element.body, order: $0.offset)
        }
        let mappedAssumptions = assumptions.map { PlanAssumption(text: $0, isAccepted: true) }
        let mappedRisks = risks.map {
            PlanRisk(text: $0.text, mitigation: $0.mitigation, severity: $0.severity)
        }
        let mappedCriteria = acceptanceCriteria.map {
            PlanCriterion(text: $0.text, verification: $0.verification)
        }
        if let prior {
            return prior.revised(
                status: .ready,
                title: title,
                summary: summary,
                sections: mappedSections,
                assumptions: mappedAssumptions,
                risks: mappedRisks,
                acceptanceCriteria: mappedCriteria,
                executionRecommendation: executionRecommendation,
                recommendationReason: recommendationReason
            )
        }
        return PlanDraft(
            conversationID: conversationID,
            status: .ready,
            title: title,
            summary: summary,
            sections: mappedSections,
            assumptions: mappedAssumptions,
            risks: mappedRisks,
            acceptanceCriteria: mappedCriteria,
            executionRecommendation: executionRecommendation,
            recommendationReason: recommendationReason
        )
    }

    public static let toolName = "plan.submit"
    public static let toolDescription =
        "Submit a complete implementation plan for user review. Call exactly once after read-only investigation; never emit a pseudo tool call in text."
    public static let parametersJSON = #"""
    {
      "type":"object",
      "properties":{
        "title":{"type":"string"},
        "summary":{"type":"string"},
        "sections":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string"}},"required":["title","body"],"additionalProperties":false}},
        "assumptions":{"type":"array","items":{"type":"string"}},
        "risks":{"type":"array","items":{"type":"object","properties":{"text":{"type":"string"},"mitigation":{"type":"string"},"severity":{"type":"string","enum":["low","medium","high"]}},"required":["text","mitigation","severity"],"additionalProperties":false}},
        "acceptanceCriteria":{"type":"array","items":{"type":"object","properties":{"text":{"type":"string"},"verification":{"type":"string"}},"required":["text","verification"],"additionalProperties":false}},
        "executionRecommendation":{"type":"string","enum":["normal","goal"]},
        "recommendationReason":{"type":"string"}
      },
      "required":["title","summary","sections","assumptions","risks","acceptanceCriteria","executionRecommendation","recommendationReason"],
      "additionalProperties":false
    }
    """#
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
